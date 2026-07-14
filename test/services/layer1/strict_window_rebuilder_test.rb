# frozen_string_literal: true

require "test_helper"

module Layer1
  class StrictWindowRebuilderTest < ActiveSupport::TestCase
    AuditResult = Struct.new(:status, :id, :issues, keyword_init: true)

    class FakeRedis
      def initialize
        @lists = Hash.new { |hash, key| hash[key] = [] }
      end

      def pipelined
        yield self
      end

      def rpush(key, value)
        @lists[key] << value
      end

      def lpush(key, *values)
        @lists[key].unshift(*values)
      end

      def lpop(key, count)
        @lists[key].shift(count)
      end

      def llen(key)
        @lists[key].size
      end
    end

    class FakeRpc
      attr_reader :getblock_calls

      def initialize(height:, block_hash:, block:)
        @height = height
        @block_hash = block_hash
        @block = block
        @getblock_calls = []
      end

      def getblockhash(height)
        raise "unexpected height #{height}" unless height == @height

        @block_hash
      end

      def getblock(block_hash, verbosity)
        raise "unexpected block hash #{block_hash}" unless block_hash == @block_hash

        @getblock_calls << verbosity

        return header if verbosity == 1
        return @block if verbosity == 3

        raise "unexpected verbosity #{verbosity}"
      end

      private

      def header
        {
          "previousblockhash" => "0" * 64,
          "nTx" => @block.fetch("tx").size,
          "size" => 123_456,
          "time" => @block.fetch("time")
        }
      end
    end

    test "strict path uses verbosity 3 vin prevout without bulk tx output resolver" do
      height = 956_020
      block_hash = "1" * 64
      previous_txid = "a" * 64
      spending_txid = "d" * 64
      rpc = FakeRpc.new(
        height: height,
        block_hash: block_hash,
        block: block_payload(
          previous_txid: previous_txid,
          spending_txid: spending_txid
        )
      )

      run_strict_rebuilder(height: height, rpc: rpc)

      assert_includes rpc.getblock_calls, 3

      cluster_input = ClusterInput.find_by!(txid: previous_txid, vout: 0)
      assert_equal "bc1qprevout", cluster_input.address
      assert_equal BigDecimal("2.50"), cluster_input.amount_btc
      assert_equal 955_000, cluster_input.block_height
      assert_equal spending_txid, cluster_input.spent_txid
      assert_equal height, cluster_input.spent_block_height
    end

    test "creates tx output projection checkpoint after certification" do
      height = 956_021
      block_hash = "2" * 64
      rpc = FakeRpc.new(
        height: height,
        block_hash: block_hash,
        block: block_payload(
          previous_txid: "b" * 64,
          spending_txid: "e" * 64
        )
      )

      result = run_strict_rebuilder(height: height, rpc: rpc)

      assert result[:ok]

      checkpoint = Layer1TxOutputProjectionBlock.find_by!(height: height)
      assert_equal block_hash, checkpoint.block_hash
      assert_equal "pending", checkpoint.status
      assert_equal 2, checkpoint.expected_outputs_count
      assert_equal BigDecimal("1.75"), checkpoint.expected_outputs_value_btc
      assert_equal 0, TxOutput.where(block_height: height).count
    end

    test "flushes spent outputs in realtime mode" do
      height = 956_023
      block_hash = "4" * 64
      modes = []
      original_call =
        Blockchain::Flushers::SpentOutputFlusherSelector.method(:call)

      rpc = FakeRpc.new(
        height: height,
        block_hash: block_hash,
        block: block_payload(
          previous_txid: "4" * 64,
          spending_txid: "5" * 64
        )
      )

      with_stubbed(
        Blockchain::Flushers::SpentOutputFlusherSelector,
        :call,
        lambda do |*args, **kwargs|
          modes << kwargs[:mode]
          original_call.call(*args, **kwargs)
        end
      ) do
        result = run_strict_rebuilder(height: height, rpc: rpc)

        assert result[:ok]
      end

      assert_includes modes, :realtime
    end

    test "does not create tx output projection checkpoint when certification fails" do
      height = 956_022
      block_hash = "3" * 64
      rpc = FakeRpc.new(
        height: height,
        block_hash: block_hash,
        block: block_payload(
          previous_txid: "c" * 64,
          spending_txid: "f" * 64
        )
      )

      result =
        run_strict_rebuilder(
          height: height,
          rpc: rpc,
          output_audit: AuditResult.new(
            status: "failed",
            id: 43,
            issues: [{ check: "outputs_count_matches" }]
          )
        )

      assert_not result[:ok]
      assert_equal "audit_outputs", result[:failed][:stage]
      assert_nil Layer1TxOutputProjectionBlock.find_by(height: height)
      assert_nil Layer1TxOutputSync.find_by(height: height)
      assert_not_equal "processed", BlockBufferModel.find_by!(height: height).status
    end

    test "certification path does not read aggregate audit state" do
      height = 956_024
      block_hash = "5" * 64
      rpc = FakeRpc.new(
        height: height,
        block_hash: block_hash,
        block: block_payload(
          previous_txid: "6" * 64,
          spending_txid: "7" * 64
        )
      )

      with_stubbed(
        Layer1::Audit::OperationalSnapshot,
        :call,
        ->(*) { raise "aggregate audit state must not gate certification" }
      ) do
        result = run_strict_rebuilder(height: height, rpc: rpc)

        assert result[:ok]
      end
    end

    test "reconciles strict UTXO state between flush and strict audits" do
      height = 956_025
      events = []
      reconcile_heights = []
      inputs_audit_result = healthy_inputs_audit
      utxo_audit_result = healthy_utxo_audit
      output_audit_result = AuditResult.new(status: "healthy", id: 42, issues: [])
      original_flusher =
        Blockchain::Flushers::SpentOutputFlusherSelector.method(:call)
      original_register =
        Layer1::TxOutputsSpentSync::Register.method(:call)
      previous_async = ENV["TX_OUTPUTS_SPENT_ASYNC"]
      rpc = FakeRpc.new(
        height: height,
        block_hash: "6" * 64,
        block: block_payload(
          previous_txid: "8" * 64,
          spending_txid: "a" * 64
        )
      )

      ENV["TX_OUTPUTS_SPENT_ASYNC"] = "0"

      begin
        with_stubbed(
          Layer1::TxOutputsSpentSync::Register,
          :call,
          lambda do |height:, block_hash:|
            events << :register_tx_outputs_sync
            original_register.call(height: height, block_hash: block_hash)
          end
        ) do
          with_stubbed(
            Blockchain::Flushers::SpentOutputFlusherSelector,
            :call,
            lambda do |*args, **kwargs|
              events << :flush
              original_flusher.call(*args, **kwargs)
            end
          ) do
            result = run_strict_rebuilder(
              height: height,
              rpc: rpc,
              reconcile: lambda do |height:|
                reconcile_heights << height
                events << :reconcile_strict_utxo
                { ok: true, height: height }
              end,
              output_audit: lambda do |height:|
                events << :audit_outputs
                output_audit_result
              end,
              inputs_audit: lambda do |height:|
                events << :audit_inputs
                inputs_audit_result
              end,
              utxo_audit: lambda do |height:|
                events << :audit_utxo_state
                utxo_audit_result
              end
            )

            assert result[:ok]
          end
        end
      ensure
        if previous_async.nil?
          ENV.delete("TX_OUTPUTS_SPENT_ASYNC")
        else
          ENV["TX_OUTPUTS_SPENT_ASYNC"] = previous_async
        end
      end

      assert_equal [height], reconcile_heights
      assert_operator events.index(:flush), :<, events.index(:reconcile_strict_utxo)
      assert_operator events.index(:reconcile_strict_utxo), :<, events.index(:audit_outputs)
      assert_operator events.index(:reconcile_strict_utxo), :<, events.index(:audit_inputs)
      assert_operator events.index(:reconcile_strict_utxo), :<, events.index(:audit_utxo_state)
      assert_operator events.index(:audit_outputs), :<, events.index(:register_tx_outputs_sync)
      assert_operator events.index(:audit_inputs), :<, events.index(:register_tx_outputs_sync)
      assert_operator events.index(:audit_utxo_state), :<, events.index(:register_tx_outputs_sync)
      assert_equal 1, events.count(:reconcile_strict_utxo)
      assert_equal 1, events.count(:register_tx_outputs_sync)
      assert Layer1TxOutputSync.exists?(height: height)
    end

    test "rolls back finalization when checkpoint registration fails" do
      block = create_processing_block(height: 956_030, block_hash: "7" * 64)
      error = RuntimeError.new("register failed")

      raised = assert_raises(RuntimeError) do
        with_stubbed(
          Layer1::TxOutputsSpentSync::Register,
          :call,
          ->(**) { raise error }
        ) do
          finalize_block(block)
        end
      end

      assert_same error, raised
      assert_equal "processing", block.reload.status
      assert_nil Layer1TxOutputSync.find_by(height: block.height)
    end

    test "rolls back checkpoint when mark processed returns false" do
      block = create_processing_block(height: 956_031, block_hash: "8" * 64)

      assert_raises(StrictWindowRebuilder::MarkProcessedFailed) do
        with_stubbed(Blockchain::Buffer::BlockBuffer, :mark_processed, false) do
          finalize_block(block)
        end
      end

      assert_equal "processing", block.reload.status
      assert_nil Layer1TxOutputSync.find_by(height: block.height)
    end

    test "rolls back checkpoint when mark processed raises" do
      block = create_processing_block(height: 956_032, block_hash: "9" * 64)
      error = RuntimeError.new("mark failed")

      raised = assert_raises(RuntimeError) do
        with_stubbed(
          Blockchain::Buffer::BlockBuffer,
          :mark_processed,
          ->(*) { raise error }
        ) do
          finalize_block(block)
        end
      end

      assert_same error, raised
      assert_equal "processing", block.reload.status
      assert_nil Layer1TxOutputSync.find_by(height: block.height)
    end

    test "rejects a block hash change before either final write" do
      block = create_processing_block(height: 956_033, block_hash: "a" * 64)

      assert_raises(StrictWindowRebuilder::BlockHashChanged) do
        finalize_block(block, block_hash: "b" * 64)
      end

      assert_equal "processing", block.reload.status
      assert_nil Layer1TxOutputSync.find_by(height: block.height)
    end

    test "commits processed block and checkpoint together" do
      block = create_processing_block(height: 956_034, block_hash: "c" * 64)

      checkpoint = finalize_block(block)

      assert_equal "processed", block.reload.status
      assert_equal block.height, checkpoint.height
      assert_equal block.block_hash, checkpoint.block_hash
      assert_equal "pending", checkpoint.status
    end

    test "reuses the same checkpoint when finalization is replayed" do
      block = create_processing_block(height: 956_035, block_hash: "d" * 64)

      first = finalize_block(block)
      second = finalize_block(block.reload)

      assert_equal first.id, second.id
      assert_equal 1, Layer1TxOutputSync.where(height: block.height).count
      assert_equal "processed", block.reload.status
    end

    test "keeps configuration scheduling and heavy work outside final transaction" do
      source = File.read(
        Rails.root.join("app/services/layer1/strict_window_rebuilder.rb")
      )
      finalizer = source[/def finalize_block!.*?(?=\n    def enqueue_tx_outputs_async_sync)/m]

      assert_not_nil finalizer
      assert_match(/ApplicationRecord\.transaction/, finalizer)
      assert_match(/BlockBufferModel\.lock\.find_by!/, finalizer)
      assert_match(/TxOutputsSpentSync::Register\.call/, finalizer)
      assert_match(/BlockBuffer\.mark_processed/, finalizer)
      refute_match(/Config\.enabled\?/, source)
      refute_match(/Sidekiq|perform_(?:async|in)|BitcoinRpc|AuditBlock/, finalizer)
    end

    private

    def create_processing_block(height:, block_hash:)
      BlockBufferModel.create!(
        height: height,
        block_hash: block_hash,
        status: "processing"
      )
    end

    def finalize_block(block, block_hash: block.block_hash)
      StrictWindowRebuilder
        .allocate
        .send(
          :finalize_block!,
          height: block.height,
          block_hash: block_hash,
          final_metrics: { strict_rebuild: true }
        )
    end

    def run_strict_rebuilder(
      height:,
      rpc:,
      output_audit: AuditResult.new(status: "healthy", id: 42, issues: []),
      reconcile: nil,
      inputs_audit: nil,
      utxo_audit: nil
    )
      redis = FakeRedis.new
      original_spent_flusher_v2 = ENV["SPENT_OUTPUT_FLUSHER_V2"]
      original_fast_path = ENV["LAYER1_FAST_PATH"]
      reconcile ||= { ok: true, height: height }
      inputs_audit ||= healthy_inputs_audit
      utxo_audit ||= healthy_utxo_audit

      ENV["SPENT_OUTPUT_FLUSHER_V2"] = "1"
      ENV["LAYER1_FAST_PATH"] = "true"

      with_stubbed(Redis, :new, redis) do
        with_stubbed(
          Blockchain::Processing::BulkPrevoutResolver,
          :new,
          ->(*) { raise "BulkPrevoutResolver must not be used by strict V5" }
        ) do
          with_stubbed(
            Layer1::TxOutputProjection::ProjectHeight,
            :call,
            ->(*) { raise "ProjectHeight must not run inline" }
          ) do
            with_stubbed(
              Layer1::ReconcileSpentOutputs,
              :call,
              ->(*) { raise "legacy reconciliation must not run" }
            ) do
              with_stubbed(Layer1::ReconcileStrictUtxoState, :call, reconcile) do
                with_stubbed(Layer1::AuditBlock, :call, output_audit) do
                  with_stubbed(Layer1::AuditBlockInputs, :call, inputs_audit) do
                    with_stubbed(Layer1::AuditBlockUtxoState, :call, utxo_audit) do
                      Layer1::StrictWindowRebuilder.call(
                        from_height: height,
                        to_height: height,
                        rpc: rpc
                      )
                    end
                  end
                end
              end
            end
          end
        end
      end
    ensure
      ENV["SPENT_OUTPUT_FLUSHER_V2"] = original_spent_flusher_v2
      ENV["LAYER1_FAST_PATH"] = original_fast_path
    end

    def healthy_inputs_audit
      {
        ok: true,
        node_inputs_count: 1,
        db_inputs_count: 1,
        node_inputs_value_btc: BigDecimal("2.50"),
        db_inputs_value_btc: BigDecimal("2.50")
      }
    end

    def healthy_utxo_audit
      {
        ok: true,
        expected_live_outputs_count: 2,
        actual_live_utxos_count: 2,
        expected_live_value_btc: BigDecimal("1.75"),
        actual_live_value_btc: BigDecimal("1.75"),
        spent_rows_still_in_utxo: 0,
        orphan_utxos_count: 0,
        spent_utxos_count: 1
      }
    end

    def block_payload(previous_txid:, spending_txid:)
      {
        "hash" => "unused",
        "time" => 1_781_780_400,
        "tx" => [
          {
            "txid" => "9" * 64,
            "vin" => [{ "coinbase" => "00" }],
            "vout" => [
              output_payload(0, "bc1qcoinbase", "1.00")
            ]
          },
          {
            "txid" => spending_txid,
            "vin" => [
              {
                "txid" => previous_txid,
                "vout" => 0,
                "prevout" => {
                  "height" => 955_000,
                  "value" => "2.50",
                  "scriptPubKey" => {
                    "address" => "bc1qprevout"
                  }
                }
              }
            ],
            "vout" => [
              output_payload(0, "bc1qspending", "0.75")
            ]
          }
        ]
      }
    end

    def output_payload(n, address, value)
      {
        "n" => n,
        "value" => value,
        "scriptPubKey" => {
          "address" => address
        }
      }
    end

    def with_stubbed(object, method_name, value = nil)
      original = object.method(method_name)
      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs) { value }
        end

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end

  class StrictWindowRebuilderAtomicVisibilityTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    HEIGHT = 956_090

    setup do
      Layer1TxOutputSync.where(height: HEIGHT).delete_all
      BlockBufferModel.where(height: HEIGHT).delete_all
    end

    teardown do
      Layer1TxOutputSync.where(height: HEIGHT).delete_all
      BlockBufferModel.where(height: HEIGHT).delete_all
    end

    test "publishes checkpoint and processed block in one PostgreSQL commit" do
      block = BlockBufferModel.create!(
        height: HEIGHT,
        block_hash: "e" * 64,
        status: "processing"
      )
      updated = Queue.new
      release = Queue.new
      original_mark_processed =
        Blockchain::Buffer::BlockBuffer.method(:mark_processed)

      Blockchain::Buffer::BlockBuffer.define_singleton_method(
        :mark_processed
      ) do |height, metrics:|
        result = original_mark_processed.call(height, metrics: metrics)
        updated << true
        release.pop
        result
      end

      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          StrictWindowRebuilder
            .allocate
            .send(
              :finalize_block!,
              height: block.height,
              block_hash: block.block_hash,
              final_metrics: { strict_rebuild: true }
            )
        end
      end

      updated.pop

      ActiveRecord::Base.uncached do
        assert_equal "processing", BlockBufferModel.find(block.id).status
        assert_nil Layer1TxOutputSync.find_by(height: block.height)
      end

      release << true
      checkpoint = thread.value
      thread = nil

      ActiveRecord::Base.uncached do
        assert_equal "processed", BlockBufferModel.find(block.id).status
        assert_equal checkpoint.id, Layer1TxOutputSync.find_by!(height: block.height).id
      end
    ensure
      release << true if thread&.alive?
      thread&.join

      if original_mark_processed
        Blockchain::Buffer::BlockBuffer.define_singleton_method(
          :mark_processed
        ) do |*args, **kwargs, &callback|
          original_mark_processed.call(*args, **kwargs, &callback)
        end
      end
    end
  end
end
