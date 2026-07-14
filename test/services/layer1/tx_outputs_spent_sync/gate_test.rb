# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Layer1
  module TxOutputsSpentSync
    class GateTest < ActiveSupport::TestCase
      FakeRedis = Struct.new(:outputs, :spent) do
        def llen(key)
          return outputs if key == Gate::OUTPUTS_KEY
          return spent if key == Gate::SPENT_KEY

          raise "unexpected Redis key: #{key}"
        end
      end

      FakeRpc = Struct.new(:height) do
        def getblockcount
          height
        end
      end

      setup do
        @previous_enabled = ENV["TX_OUTPUTS_SPENT_ASYNC"]
        ENV["TX_OUTPUTS_SPENT_ASYNC"] = "1"

        @layer1 = BlockBufferModel.create!(
          height: 96,
          block_hash: "1" * 64,
          status: "processed"
        )
        @cluster = ClusterProcessedBlock.create!(
          height: 90,
          block_hash: "2" * 64,
          status: "processed"
        )
        @checkpoint = Layer1TxOutputSync.create!(
          height: 80,
          block_hash: "3" * 64,
          status: "pending"
        )
      end

      teardown do
        if @previous_enabled.nil?
          ENV.delete("TX_OUTPUTS_SPENT_ASYNC")
        else
          ENV["TX_OUTPUTS_SPENT_ASYNC"] = @previous_enabled
        end
      end

      test "allows work only when every historical guard is satisfied" do
        checkpoint_attributes = @checkpoint.attributes

        result = NextRecord.stub(:call, -> { flunk("Gate must not claim work") }) do
          assert_no_queries_match(/\b(?:INSERT|UPDATE|DELETE)\b/i) do
            build_gate.call
          end
        end

        assert_equal true, result[:ready]
        assert_empty result[:reasons]
        assert_equal true, result[:work_available]
        assert_equal 4, result[:lag]
        assert_equal 6, result[:cluster_lag]
        assert_nil result[:processing_height]
        assert_nil result[:cluster_processing_height]
        assert_equal checkpoint_attributes, @checkpoint.reload.attributes
      end

      test "refuses when the feature is disabled without probing dependencies" do
        ENV["TX_OUTPUTS_SPENT_ASYNC"] = "0"
        unavailable = Object.new
        unavailable.define_singleton_method(:call) { raise "must not be called" }
        redis = Object.new
        redis.define_singleton_method(:llen) { |_key| raise "must not be called" }
        rpc = Object.new
        rpc.define_singleton_method(:getblockcount) { raise "must not be called" }

        result = Gate.new(
          redis: redis,
          rpc: rpc,
          work_available: unavailable
        ).call

        assert_refusal result, "async_sync_disabled"
      end

      test "refuses without a Layer1 checkpoint" do
        @layer1.destroy!

        result = build_gate(rpc_height: 0).call

        assert_refusal result, "layer1_checkpoint_unavailable"
      end

      test "refuses while Layer1 is processing" do
        BlockBufferModel.create!(
          height: 97,
          block_hash: "4" * 64,
          status: "processing"
        )

        result = build_gate.call

        assert_refusal result, "layer1_processing"
      end

      test "refuses while strict Redis buffers are not empty" do
        result = build_gate(outputs: 1, spent: 2).call

        assert_refusal result, "buffers_not_empty"
      end

      test "refuses when Layer1 lag exceeds its historical budget" do
        result = build_gate(rpc_height: 103).call

        assert_refusal result, "layer1_lag_above_historical_budget"
      end

      test "refuses without a Cluster checkpoint" do
        @cluster.destroy!

        result = build_gate.call

        assert_refusal result, "cluster_checkpoint_unavailable"
      end

      test "refuses while Cluster is processing" do
        ClusterProcessedBlock.create!(
          height: 91,
          block_hash: "5" * 64,
          status: "processing"
        )

        result = build_gate.call

        assert_refusal result, "cluster_processing"
      end

      test "refuses when Cluster lag exceeds its historical budget" do
        @cluster.update!(height: 83)

        result = build_gate.call

        assert_refusal result, "cluster_lag_above_historical_budget"
      end

      test "refuses when no checkpoint is eligible without claiming one" do
        @checkpoint.update!(status: "synced")
        checkpoint_attributes = @checkpoint.attributes

        result = build_gate.call

        assert_refusal result, "no_eligible_checkpoint"
        assert_equal checkpoint_attributes, @checkpoint.reload.attributes
      end

      test "fails closed on Redis errors" do
        redis = Object.new
        redis.define_singleton_method(:llen) { |_key| raise IOError, "redis unavailable" }

        result = build_gate(redis: redis).call

        assert_gate_error result, IOError
      end

      test "fails closed on Bitcoin Core errors" do
        rpc = Object.new
        rpc.define_singleton_method(:getblockcount) { raise IOError, "rpc unavailable" }

        result = build_gate(rpc: rpc).call

        assert_gate_error result, IOError
      end

      test "fails closed when the Layer1 checkpoint query fails" do
        result = BlockBufferModel.stub(
          :where,
          ->(*_args) { raise ActiveRecord::StatementInvalid, "checkpoint unavailable" }
        ) do
          build_gate.call
        end

        assert_gate_error result, ActiveRecord::StatementInvalid
      end

      test "fails closed when the Cluster checkpoint query fails" do
        result = ClusterProcessedBlock.stub(
          :where,
          ->(*_args) { raise ActiveRecord::StatementInvalid, "cluster unavailable" }
        ) do
          build_gate.call
        end

        assert_gate_error result, ActiveRecord::StatementInvalid
      end

      test "fails closed on configuration errors" do
        result = Config.stub(:enabled?, -> { raise ArgumentError, "invalid config" }) do
          build_gate.call
        end

        assert_gate_error result, ArgumentError
      end

      test "fails closed when the availability probe returns an unexpected state" do
        result = build_gate(work_available: -> { nil }).call

        assert_refusal result, "no_eligible_checkpoint"
      end

      test "fails closed when the availability probe raises" do
        result = build_gate(
          work_available: -> { raise RuntimeError, "unexpected checkpoint state" }
        ).call

        assert_gate_error result, RuntimeError
      end

      private

      def build_gate(
        outputs: 0,
        spent: 0,
        rpc_height: 100,
        redis: FakeRedis.new(outputs, spent),
        rpc: FakeRpc.new(rpc_height),
        work_available: WorkAvailable
      )
        Gate.new(
          redis: redis,
          rpc: rpc,
          work_available: work_available
        )
      end

      def assert_refusal(result, reason)
        assert_equal false, result[:ready]
        assert_equal [reason], result[:reasons]
      end

      def assert_gate_error(result, error_class)
        assert_equal false, result[:ready]
        assert_equal error_class.name, result[:error_class]
        assert_equal 1, result[:reasons].size
        assert_match(/\Agate_error=#{Regexp.escape(error_class.name)}:/, result[:reasons].first)
      end
    end
  end
end
