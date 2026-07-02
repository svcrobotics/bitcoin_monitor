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

    private

    def run_strict_rebuilder(
      height:,
      rpc:,
      output_audit: AuditResult.new(status: "healthy", id: 42, issues: [])
    )
      redis = FakeRedis.new
      original_spent_flusher_v2 = ENV["SPENT_OUTPUT_FLUSHER_V2"]
      original_fast_path = ENV["LAYER1_FAST_PATH"]

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
            with_stubbed(Layer1::ReconcileSpentOutputs, :call, { ok: true, height: height }) do
              with_stubbed(Layer1::AuditBlock, :call, output_audit) do
                with_stubbed(
                  Layer1::AuditBlockInputs,
                  :call,
                  {
                    ok: true,
                    node_inputs_count: 1,
                    db_inputs_count: 1,
                    node_inputs_value_btc: BigDecimal("2.50"),
                    db_inputs_value_btc: BigDecimal("2.50")
                  }
                ) do
                  with_stubbed(
                    Layer1::AuditBlockUtxoState,
                    :call,
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
                  ) do
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
    ensure
      ENV["SPENT_OUTPUT_FLUSHER_V2"] = original_spent_flusher_v2
      ENV["LAYER1_FAST_PATH"] = original_fast_path
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
end
