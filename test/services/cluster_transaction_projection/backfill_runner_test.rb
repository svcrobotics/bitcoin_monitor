# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class BackfillRunnerTest < ActiveSupport::TestCase
    def setup
      StrictPipeline::StrictIoLease.clear!
      @checkpoint = 10
      @hash = Digest::SHA256.hexdigest("checkpoint")
      ClusterProcessedBlock.create!(
        height: @checkpoint,
        block_hash: @hash,
        status: "processed",
        processed_at: Time.current
      )
    end

    teardown do
      StrictPipeline::StrictIoLease.clear!
    end

    test "creates run items and certifies exact deduplicated counts" do
      cluster = cluster_with_addresses("a", "b")
      seed_activity(cluster)

      result =
        BackfillRunner.call(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 2
        )

      assert_equal true, result.ok
      assert_equal :completed, result.reason

      generation =
        ClusterTransactionProjectionGeneration.find_by!(
          cluster_id: cluster.id,
          status: "certified"
        )

      assert_equal "pilot_backfill", generation.source
      assert_equal @checkpoint, generation.base_checkpoint_height
      assert_equal @hash, generation.base_checkpoint_hash
      assert_equal 5, generation.inflow_count
      assert_equal 2, generation.outflow_count
      assert_equal 6, generation.tx_count
      assert_equal 6, generation.facts_count

      readiness =
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @checkpoint,
          composition_version: cluster.composition_version
        )

      assert_equal true, readiness.ready?
      assert_equal(
        {
          inflow_count: 5,
          outflow_count: 2,
          tx_count: 6
        },
        readiness.counts
      )
    end

    test "pause and resume continue from durable cursor without duplicates" do
      cluster = cluster_with_addresses("pause-a", "pause-b")
      seed_activity(cluster)

      first =
        BackfillRunner.call(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 1,
          pause_after_chunks: 1
        )

      assert_equal :pause_requested, first.reason
      run = first.run.reload
      item = run.items.first
      cursor_after_pause =
        item.source_cursor.fetch("cluster_inputs_received")

      assert_operator cursor_after_pause, :>, 0
      assert_equal "paused", run.status
      assert_nil StrictPipeline::StrictIoLease.current

      second =
        BackfillRunner.call(
          run_id: run.id,
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 1
        )

      assert_equal :completed, second.reason

      item.reload
      assert_operator(
        item.source_cursor.fetch("cluster_inputs_received"),
        :>=,
        cursor_after_pause
      )

      generation =
        ClusterTransactionProjectionGeneration.find_by!(
          cluster_id: cluster.id,
          status: "certified"
        )

      assert_equal 6, generation.facts_count
      assert_equal(
        6,
        ClusterTransactionFact
          .where(projection_generation_id: generation.id)
          .count
      )
    end

    test "controlled interruption after committed chunk resumes idempotently" do
      cluster = cluster_with_addresses("stop-a", "stop-b")
      seed_activity(cluster)

      first =
        BackfillRunner.call(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 1,
          stop_after_chunks: 1
        )

      assert_equal :stopped_after_chunk, first.reason
      assert_equal "running", first.run.reload.status
      assert_nil StrictPipeline::StrictIoLease.current

      second =
        BackfillRunner.call(
          run_id: first.run.id,
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 1
        )

      assert_equal :completed, second.reason

      generation =
        ClusterTransactionProjectionGeneration.find_by!(
          cluster_id: cluster.id,
          status: "certified"
        )

      assert_equal 6, generation.facts_count
    end

    test "materialized source chunks bound work before joins and resume by cursor" do
      cluster = cluster_with_addresses("bounded")
      address = Address.find_by!(cluster_id: cluster.id).address

      first_input =
        create_cluster_input(
          txid: txid("bounded-received-1"),
          address: address,
          block_height: 1,
          spent_txid: txid("bounded-spent-1"),
          spent_block_height: 2
        )
      outside_input =
        create_cluster_input(
          txid: txid("bounded-outside"),
          address: "bounded-outside",
          block_height: 1
        )
      second_input =
        create_cluster_input(
          txid: txid("bounded-received-2"),
          address: address,
          block_height: 3,
          spent_txid: txid("bounded-spent-2"),
          spent_block_height: 4
        )
      create_cluster_input(
        txid: txid("bounded-future"),
        address: address,
        block_height: @checkpoint + 1,
        vout: 9
      )

      UtxoOutput.create!(
        txid: txid("bounded-utxo-1"),
        vout: 0,
        address: address,
        block_height: 5
      )
      UtxoOutput.create!(
        txid: txid("bounded-utxo-future"),
        vout: 0,
        address: address,
        block_height: @checkpoint + 1
      )

      captured_sql = []
      callback = lambda do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        captured_sql << sql if sql.include?("source_chunk")
      end

      first =
        ActiveSupport::Notifications.subscribed(
          callback,
          "sql.active_record"
        ) do
          BackfillRunner.call(
            cluster_ids: [cluster.id],
            target_checkpoint_height: @checkpoint,
            target_checkpoint_hash: @hash,
            chunk_size: 2,
            max_chunks: 1
          )
        end

      assert_equal :max_chunks, first.reason
      assert(
        captured_sql.any? { |sql|
          sql.include?("WITH source_chunk AS MATERIALIZED")
        }
      )

      run = first.run.reload
      item = run.items.first
      generation = item.projection_generation

      assert_equal(
        outside_input.id,
        item.source_cursor.fetch("cluster_inputs_received")
      )
      assert_equal(
        [txid("bounded-received-1")],
        fact_txids(generation)
      )
      assert_not_includes fact_txids(generation), txid("bounded-received-2")

      item.update!(
        source_cursor: {
          "cluster_inputs_received" => 0
        },
        status: "paused"
      )
      run.update!(status: "paused")

      replay =
        BackfillRunner.call(
          run_id: run.id,
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 2,
          max_chunks: 1
        )

      assert_equal :max_chunks, replay.reason
      item.reload
      assert_equal(
        outside_input.id,
        item.source_cursor.fetch("cluster_inputs_received")
      )
      assert_equal(
        [txid("bounded-received-1")],
        fact_txids(generation)
      )

      next_chunk =
        BackfillRunner.call(
          run_id: run.id,
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 2,
          max_chunks: 1
        )

      assert_equal :max_chunks, next_chunk.reason
      item.reload
      assert_equal(
        second_input.id,
        item.source_cursor.fetch("cluster_inputs_received")
      )
      assert_includes fact_txids(generation), txid("bounded-received-2")

      completed =
        BackfillRunner.call(
          run_id: run.id,
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 2
        )

      assert_equal :completed, completed.reason
      item.reload
      generation.reload

      assert_equal(
        source_cursor_max(
          ClusterInput,
          height_column: :block_height,
          txid_column: :txid
        ),
        item.source_cursor.fetch("cluster_inputs_received")
      )
      assert_equal(
        source_cursor_max(
          UtxoOutput,
          height_column: :block_height,
          txid_column: :txid
        ),
        item.source_cursor.fetch("utxo_outputs_received")
      )
      assert_equal(
        source_cursor_max(
          ClusterInput,
          height_column: :spent_block_height,
          txid_column: :spent_txid
        ),
        item.source_cursor.fetch("cluster_inputs_spent")
      )

      assert_equal "certified", generation.status
      assert_equal 3, generation.inflow_count
      assert_equal 2, generation.outflow_count
      assert_equal 5, generation.tx_count
      assert_equal 5, generation.facts_count
      assert_not_includes fact_txids(generation), txid("bounded-future")
      assert_not_includes fact_txids(generation), txid("bounded-utxo-future")
    end

    test "plan! creates metadata only while strict io is held" do
      cluster = cluster_with_addresses("lock-a")
      seed_activity(cluster)

      lease =
        StrictPipeline::StrictIoLease.acquire("layer1")
      assert lease

      captured_sql = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql = payload[:sql].to_s
          captured_sql << sql if sql.match?(/cluster_inputs|utxo_outputs/i)
        end

      run =
        ActiveSupport::Notifications.subscribed(
          callback,
          "sql.active_record"
        ) do
          BackfillRunner.plan!(
            cluster_ids: [cluster.id],
            target_checkpoint_height: @checkpoint,
            target_checkpoint_hash: @hash,
            source: "scheduler_experiment"
          )
        end

      assert_equal "pending", run.status
      assert_equal 1, run.items.count
      assert_equal 0, run.addresses.count
      assert_equal 0, ClusterTransactionProjectionGeneration.count
      assert_equal 0, ClusterTransactionFact.count
      assert_equal(
        [],
        captured_sql.select do |sql|
          sql.match?(/cluster_inputs|utxo_outputs/i)
        end
      )
      assert_nil run.items.first.projection_generation_id
    ensure
      StrictPipeline::StrictIoLease.release(
        owner: lease.owner,
        token: lease.token
      ) if lease
    end

    test "plan! is idempotent for the same cluster and checkpoint" do
      cluster = cluster_with_addresses("plan-idempotent")
      seed_activity(cluster)

      first =
        BackfillRunner.plan!(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          source: "scheduler_experiment"
        )

      second =
        BackfillRunner.plan!(
        cluster_ids: [cluster.id],
        target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          source: "scheduler_experiment"
        )

      assert_equal first.id, second.id
      assert_equal 1, ClusterTransactionProjectionBackfillRun.count
      assert_equal 1, ClusterTransactionProjectionBackfillItem.count
    end

    test "checkpoint drift before first tranche marks run stale" do
      cluster = cluster_with_addresses("stale-checkpoint")
      seed_activity(cluster)

      run =
        BackfillRunner.plan!(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash
        )

      ClusterProcessedBlock
        .find_by!(height: @checkpoint)
        .update!(block_hash: Digest::SHA256.hexdigest("changed"))

      lease = lease_for("cluster_transaction_projection")

      with_stubbed(
        StrictPipeline::StrictIoLease,
        :acquire,
        ->(_owner, **_kwargs) { lease }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :release,
          ->(**_kwargs) { true }
        ) do
          assert_raises(ClusterTransactionProjection::BackfillRunner::StaleRunError) do
            BackfillRunner.call(
              run_id: run.id,
              target_checkpoint_height: @checkpoint,
              target_checkpoint_hash: @hash,
              budget_seconds: 1
            )
          end
        end
      end

      assert_equal "stale", run.reload.status
      assert_equal "cluster checkpoint changed", run.stale_reason
      assert_equal "stale", run.items.first.reload.status
    end

    test "composition drift before first tranche marks run stale" do
      cluster = cluster_with_addresses("stale-composition")
      seed_activity(cluster)

      run =
        BackfillRunner.plan!(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash
        )

      cluster.update!(composition_version: cluster.composition_version + 1)

      lease = lease_for("cluster_transaction_projection")

      with_stubbed(
        StrictPipeline::StrictIoLease,
        :acquire,
        ->(_owner, **_kwargs) { lease }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :release,
          ->(**_kwargs) { true }
        ) do
          assert_raises(ClusterTransactionProjection::BackfillRunner::StaleRunError) do
            BackfillRunner.call(
              run_id: run.id,
              target_checkpoint_height: @checkpoint,
              target_checkpoint_hash: @hash,
              budget_seconds: 1
            )
          end
        end
      end

      assert_equal "stale", run.reload.status
      assert_match(/composition revision changed/, run.stale_reason)
      assert_equal "stale", run.items.first.reload.status
    end

    test "planned run can be prepared after checkpoint remains valid" do
      cluster = cluster_with_addresses("prepare-a")
      seed_activity(cluster)

      run =
        BackfillRunner.plan!(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash
        )

      lease = lease_for("cluster_transaction_projection")

      with_stubbed(
        StrictPipeline::StrictIoLease,
        :acquire,
        ->(_owner, **_kwargs) { lease }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :release,
          ->(**_kwargs) { true }
        ) do
          result =
            BackfillRunner.call(
              run_id: run.id,
              target_checkpoint_height: @checkpoint,
              target_checkpoint_hash: @hash,
              chunk_size: 1,
              max_chunks: 0
            )

          assert_equal :max_chunks, result.reason
          assert_equal "paused", run.reload.status
          assert run.items.first.reload.projection_generation_id.present?
          assert run.addresses.exists?
        end
      end
    end

    test "refuses disk limit" do
      cluster = cluster_with_addresses("limit-a")
      seed_activity(cluster)

      assert_raises(RuntimeError) do
        BackfillRunner.call(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          min_free_bytes: 1_000_000_000_000_000
        )
      end
    end

    test "budget stops before starting an oversized slice" do
      cluster = cluster_with_addresses("budget-a")
      seed_activity(cluster)

      result =
        BackfillRunner.call(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          budget_seconds: 4,
          min_chunk_margin_seconds: 5
        )

      assert_equal :budget_exhausted, result.reason
      assert_equal 0, result.chunks_processed
      assert_equal "paused", result.run.reload.status
      assert_nil StrictPipeline::StrictIoLease.current
    end

    test "preemption pauses cleanly between chunks" do
      cluster = cluster_with_addresses("preempt-a")
      seed_activity(cluster)
      calls = 0

      result =
        BackfillRunner.call(
          cluster_ids: [cluster.id],
          target_checkpoint_height: @checkpoint,
          target_checkpoint_hash: @hash,
          chunk_size: 1,
          preemption_check:
            lambda do |_run|
              calls += 1
              calls > 1 ? :actor_profile_v5_priority : nil
            end
        )

      assert_equal :actor_profile_v5_priority, result.reason
      assert_operator result.chunks_processed, :>=, 1
      assert_equal "paused", result.run.reload.status
      assert_nil StrictPipeline::StrictIoLease.current
    end

    private

    def cluster_with_addresses(*suffixes)
      cluster = Cluster.create!(composition_version: 1)

      suffixes.each do |suffix|
        Address.create!(
          address: "addr-#{suffix}",
          cluster_id: cluster.id,
          first_seen_height: 1,
          last_seen_height: @checkpoint
        )
      end

      cluster
    end

    def seed_activity(cluster)
      addresses =
        Address
          .where(cluster_id: cluster.id)
          .order(:id)
          .to_a

      create_cluster_input(
        txid: txid("received-duplicate"),
        address: addresses.first.address,
        block_height: 1
      )
      create_cluster_input(
        txid: txid("received-duplicate"),
        address: addresses.last.address,
        block_height: 2,
        vout: 1
      )
      create_cluster_input(
        txid: txid("cross"),
        address: addresses.first.address,
        block_height: 3,
        spent_txid: txid("cross"),
        spent_block_height: 4,
        vout: 2
      )
      create_cluster_input(
        txid: txid("spent-source-a"),
        address: addresses.first.address,
        block_height: 3,
        spent_txid: txid("spent-duplicate"),
        spent_block_height: 5,
        vout: 3
      )
      create_cluster_input(
        txid: txid("spent-source-b"),
        address: addresses.last.address,
        block_height: 4,
        spent_txid: txid("spent-duplicate"),
        spent_block_height: 6,
        vout: 4
      )
      UtxoOutput.create!(
        txid: txid("live-utxo"),
        vout: 0,
        address: addresses.last.address,
        block_height: 7
      )
      create_cluster_input(
        txid: txid("ignored"),
        address: "outside",
        block_height: 1,
        vout: 5
      )
    end

    def create_cluster_input(
      txid:,
      address:,
      block_height:,
      vout: 0,
      spent_txid: nil,
      spent_block_height: nil
    )
      ClusterInput.create!(
        txid: txid,
        vout: vout,
        address: address,
        block_height: block_height,
        spent: spent_txid.present?,
        spent_txid: spent_txid,
        spent_block_height: spent_block_height
      )
    end

    def fact_txids(generation)
      ClusterTransactionFact
        .where(projection_generation_id: generation.id)
        .order(:txid)
        .pluck(Arel.sql("encode(txid, 'hex')"))
    end

    def source_cursor_max(model, height_column:, txid_column:)
      model
        .where.not(height_column => nil)
        .where("#{height_column} <= ?", @checkpoint)
        .where.not(txid_column => nil)
        .maximum(:id)
        .to_i
    end

    def txid(label)
      Digest::SHA256.hexdigest(label)
    end

    def lease_for(owner)
      StrictPipeline::StrictIoLease::Lease.new(
        owner: owner.to_s,
        token: "#{owner}-token",
        acquired_at: Time.current,
        expires_at: 2.minutes.from_now
      )
    end

    def with_stubbed(object, method_name, value = nil, &block)
      original = object.method(method_name)

      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs, &_inner_block) { value }
        end

      object.define_singleton_method(method_name) do |*args, **kwargs, &inner_block|
        replacement.call(*args, **kwargs, &inner_block)
      end

      block.call
    ensure
      object.define_singleton_method(method_name, original)
    end
  end
end
