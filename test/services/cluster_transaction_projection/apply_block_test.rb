# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class ApplyBlockTest < ActiveSupport::TestCase
    def setup
      @base_height = 4
      @block_height = 5
      @base_hash = unique_hash("base")
      @block_hash = unique_hash("block")
      @cluster = Cluster.create!(composition_version: 1)

      create_cluster_checkpoint(@base_height, @base_hash)
      create_cluster_checkpoint(@block_height, @block_hash)

      ClusterTransactionProjectionBlock.create!(
        block_height: @base_height,
        block_hash: @base_hash,
        status: "projected",
        completed_at: Time.current
      )

      @generation =
        GenerationBuilder.call(
          cluster_id: @cluster.id,
          composition_version: 1,
          checkpoint_height: @base_height,
          checkpoint_hash: @base_hash,
          facts: [
            fact("existing-received", received_height: @base_height),
            fact("existing-spent", spent_height: @base_height)
          ]
        )

      result =
        Certifier.call(@generation)

      assert_equal true, result.ok
      @generation.reload
    end

    test "applies one block atomically and advances certified generation" do
      result =
        ApplyBlock.call(
          cluster_id: @cluster.id,
          expected_composition_version: 1,
          block_height: @block_height,
          block_hash: @block_hash,
          received_txids: [
            txid("new-received"),
            txid("same-block-both")
          ],
          spent_txids: [
            txid("new-spent"),
            txid("same-block-both"),
            txid("existing-received")
          ]
        )

      assert_equal true, result.ok
      assert_equal :projected, result.reason

      @generation.reload

      assert_equal @block_height, @generation.checkpoint_height
      assert_equal @block_hash, @generation.checkpoint_hash
      assert_equal 3, @generation.inflow_count
      assert_equal 4, @generation.outflow_count
      assert_equal 5, @generation.tx_count
      assert_equal 5, @generation.facts_count

      projected =
        ClusterTransactionProjectionBlock.find_by!(
          block_height: @block_height
        )

      assert_equal "projected", projected.status
      assert_equal @block_hash, projected.block_hash
      assert projected.completed_at.present?
    end

    test "is idempotent for an already projected block" do
      ApplyBlock.call(
        cluster_id: @cluster.id,
        expected_composition_version: 1,
        block_height: @block_height,
        block_hash: @block_hash,
        received_txids: [
          txid("idempotent")
        ]
      )

      before_counts =
        @generation.reload.attributes.slice(
          "checkpoint_height",
          "inflow_count",
          "outflow_count",
          "tx_count",
          "facts_count"
        )

      result =
        ApplyBlock.call(
          cluster_id: @cluster.id,
          expected_composition_version: 1,
          block_height: @block_height,
          block_hash: @block_hash,
          received_txids: [
            txid("idempotent")
          ]
        )

      assert_equal true, result.ok
      assert_equal :already_projected, result.reason
      assert_equal(
        before_counts,
        @generation.reload.attributes.slice(
          "checkpoint_height",
          "inflow_count",
          "outflow_count",
          "tx_count",
          "facts_count"
        )
      )
    end

    test "refuses a projection gap" do
      result =
        ApplyBlock.call(
          cluster_id: @cluster.id,
          expected_composition_version: 1,
          block_height: @block_height + 1,
          block_hash: unique_hash("gap"),
          received_txids: [
            txid("gap")
          ]
        )

      assert_equal false, result.ok
      assert_equal :projection_gap, result.reason
      assert_equal @base_height, @generation.reload.checkpoint_height
    end

    test "requires an explicit expected composition version" do
      assert_raises(ArgumentError) do
        ApplyBlock.call(
          cluster_id: @cluster.id,
          block_height: @block_height,
          block_hash: @block_hash
        )
      end
    end

    test "refuses concurrent composition change" do
      @cluster.update!(composition_version: 2)

      result =
        ApplyBlock.call(
          cluster_id: @cluster.id,
          expected_composition_version: 1,
          block_height: @block_height,
          block_hash: @block_hash,
          received_txids: [
            txid("composition-change")
          ]
        )

      assert_equal false, result.ok
      assert_equal :expected_composition_mismatch, result.reason
      assert_equal @base_height, @generation.reload.checkpoint_height
    end

    test "refuses a stale expected composition without partial writes" do
      generation_before = @generation.attributes
      facts_before = ClusterTransactionFact.where(
        projection_generation_id: @generation.id
      ).order(:txid).pluck(:txid, :received_height, :spent_height)
      blocks_before = ClusterTransactionProjectionBlock.order(:block_height).pluck(
        :block_height, :block_hash, :status, :completed_at
      )
      checkpoint_before = ClusterProcessedBlock.find_by!(height: @block_height).attributes

      result = ApplyBlock.call(
        cluster_id: @cluster.id,
        expected_composition_version: 2,
        block_height: @block_height,
        block_hash: @block_hash,
        received_txids: [txid("stale-payload")]
      )

      assert_equal false, result.ok
      assert_equal :expected_composition_mismatch, result.reason
      assert_equal generation_before, @generation.reload.attributes
      assert_equal facts_before, ClusterTransactionFact.where(
        projection_generation_id: @generation.id
      ).order(:txid).pluck(:txid, :received_height, :spent_height)
      assert_equal blocks_before, ClusterTransactionProjectionBlock.order(:block_height).pluck(
        :block_height, :block_hash, :status, :completed_at
      )
      assert_equal checkpoint_before,
        ClusterProcessedBlock.find_by!(height: @block_height).attributes
    end

    test "checks the expected composition inside the transaction after row locks" do
      events = []
      generation_lock = ClusterTransactionProjectionGeneration.method(:lock)
      cluster_lock = Cluster.method(:lock)
      service = ApplyBlock.new(
        cluster_id: @cluster.id,
        expected_composition_version: 2,
        block_height: @block_height,
        block_hash: @block_hash
      )
      refused = service.method(:refused)

      ClusterTransactionProjectionGeneration.define_singleton_method(:lock) do |*args, **kwargs|
        events << :generation_lock
        generation_lock.call(*args, **kwargs)
      end
      Cluster.define_singleton_method(:lock) do |*args, **kwargs|
        events << :cluster_lock
        cluster_lock.call(*args, **kwargs)
      end
      service.define_singleton_method(:refused) do |reason, **kwargs|
        if reason == :expected_composition_mismatch
          events << :version_refused
          events << :transaction_open if ApplicationRecord.connection.transaction_open?
        end
        refused.call(reason, **kwargs)
      end

      result = service.call

      assert_equal false, result.ok
      assert_equal :expected_composition_mismatch, result.reason
      assert_operator events.index(:generation_lock), :<, events.index(:version_refused)
      assert_operator events.index(:cluster_lock), :<, events.index(:version_refused)
      assert_includes events, :transaction_open
    ensure
      ClusterTransactionProjectionGeneration.define_singleton_method(:lock, generation_lock) if generation_lock
      Cluster.define_singleton_method(:lock, cluster_lock) if cluster_lock
    end

    test "rolls back facts, counters and block state on failure" do
      service =
        ApplyBlock.new(
          cluster_id: @cluster.id,
          expected_composition_version: 1,
          block_height: @block_height,
          block_hash: @block_hash,
          received_txids: [
            txid("rollback")
          ]
        )

      def service.after_upsert_hook
        raise "forced rollback"
      end

      assert_raises(RuntimeError) do
        service.call
      end

      assert_nil(
        ClusterTransactionFact.find_by(
          projection_generation_id: @generation.id,
          txid: Txid.pack(txid("rollback"))
        )
      )

      @generation.reload
      assert_equal @base_height, @generation.checkpoint_height
      assert_equal 1, @generation.inflow_count
      assert_equal 1, @generation.outflow_count
      assert_equal 2, @generation.tx_count
      assert_equal 2, @generation.facts_count

      assert_nil(
        ClusterTransactionProjectionBlock.find_by(
          block_height: @block_height
        )
      )
    end

    private

    def create_cluster_checkpoint(height, block_hash)
      ClusterProcessedBlock.create!(
        height: height,
        block_hash: block_hash,
        status: "processed",
        processed_at: Time.current
      )
    end

    def fact(label, received_height: nil, spent_height: nil)
      {
        txid: txid(label),
        received_height: received_height,
        spent_height: spent_height
      }
    end

    def txid(label)
      Digest::SHA256.hexdigest(label)
    end

    def unique_hash(label)
      Digest::SHA256.hexdigest(
        "#{label}-#{SecureRandom.hex(8)}"
      )
    end
  end
end
