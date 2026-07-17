# frozen_string_literal: true

require "test_helper"

module Layer1
  class TxOutputProjectionJobTest < ActiveSupport::TestCase
    class FakeRedis
      attr_reader :deleted_keys

      def initialize(acquired: true)
        @acquired = acquired
        @values = {}
        @deleted_keys = []
      end

      def set(key, value, nx:, ex:)
        return nil unless @acquired

        @values[key] = value
        true
      end

      def get(key)
        @values[key]
      end

      def del(key)
        @deleted_keys << key
        @values.delete(key)
      end
    end

    test "returns disabled without projecting when config is disabled" do
      with_stubbed(Layer1::TxOutputProjection::Config, :enabled?, false) do
        result = Layer1::TxOutputProjectionJob.new.perform

        assert_equal({ ok: true, status: "disabled" }, result)
      end
    end

    test "returns idle when no projection checkpoint is pending" do
      redis = FakeRedis.new

      with_stubbed(Layer1::TxOutputProjection::Config, :enabled?, true) do
        with_allowed_heavy do
          with_stubbed(Redis, :new, redis) do
            with_stubbed(Layer1::TxOutputProjection::NextRecord, :call, nil) do
              result = Layer1::TxOutputProjectionJob.new.perform

              assert_equal({ ok: true, status: "idle" }, result)
              assert_includes redis.deleted_keys, Layer1::TxOutputProjectionJob::LOCK_KEY
            end
          end
        end
      end
    end

    test "projects the next checkpoint without touching bitcoin core directly" do
      redis = FakeRedis.new
      record =
        Layer1TxOutputProjectionBlock.create!(
          height: 955_200,
          block_hash: "1" * 64,
          status: "pending"
        )

      projected = {
        ok: true,
        status: "projected",
        height: record.height
      }

      next_records = [record, nil]
      projected_record = nil

      with_stubbed(Layer1::TxOutputProjection::Config, :enabled?, true) do
        with_allowed_heavy do
          with_stubbed(Redis, :new, redis) do
            with_stubbed(
              Layer1::TxOutputProjection::NextRecord,
              :call,
              -> { next_records.shift }
            ) do
              with_stubbed(
                Layer1::TxOutputProjection::ProjectHeight,
                :call,
                ->(projection_block:) {
                  projected_record = projection_block
                  projected
                }
              ) do
                result = Layer1::TxOutputProjectionJob.new.perform

                assert_equal projected, result
                assert_equal record, projected_record
              end
            end
          end
        end
      end
    end

    test "re-enqueues itself when more checkpoints remain" do
      redis = FakeRedis.new
      record =
        Layer1TxOutputProjectionBlock.create!(
          height: 955_201,
          block_hash: "2" * 64,
          status: "pending"
        )

      remaining =
        Layer1TxOutputProjectionBlock.create!(
          height: 955_202,
          block_hash: "3" * 64,
          status: "pending"
        )

      next_records = [record, remaining]
      enqueued_delay = nil

      with_stubbed(Layer1::TxOutputProjection::Config, :enabled?, true) do
        with_allowed_heavy do
          with_stubbed(Redis, :new, redis) do
            with_stubbed(
              Layer1::TxOutputProjection::NextRecord,
              :call,
              -> { next_records.shift }
            ) do
              with_stubbed(
                Layer1::TxOutputProjection::ProjectHeight,
                :call,
                { ok: true, status: "projected" }
              ) do
                with_stubbed(
                  Layer1::TxOutputProjectionJob,
                  :perform_in,
                  ->(delay) { enqueued_delay = delay }
                ) do
                  Layer1::TxOutputProjectionJob.new.perform
                end
              end
            end
          end
        end
      end

      assert_equal 1, enqueued_delay
    end

    test "returns locked when another projection worker owns the lock" do
      redis = FakeRedis.new(acquired: false)

      with_stubbed(Layer1::TxOutputProjection::Config, :enabled?, true) do
        with_allowed_heavy do
          with_stubbed(Redis, :new, redis) do
            result = Layer1::TxOutputProjectionJob.new.perform

            assert_equal({ ok: true, status: "locked" }, result)
          end
        end
      end
    end

    test "defers before reading next record when heavy guard denies" do
      decision = {
        allowed: false,
        reason: :cluster_strict_priority,
        failed_constraints: [:cluster_caught_up_to_layer1]
      }

      next_record_called = false

      with_stubbed(Layer1::TxOutputProjection::Config, :enabled?, true) do
        with_stubbed(
          System::PipelineController,
          :layer1_heavy_decision,
          decision
        ) do
          with_stubbed(
            Layer1::TxOutputProjection::NextRecord,
            :call,
            -> { next_record_called = true }
          ) do
            result = Layer1::TxOutputProjectionJob.new.perform

            assert_equal true, result[:ok]
            assert_equal "deferred", result[:status]
            assert_equal decision, result[:decision]
          end
        end
      end

      assert_equal false, next_record_called
    end

    private

    def with_allowed_heavy
      with_stubbed(
        System::PipelineController,
        :layer1_heavy_decision,
        { allowed: true }
      ) do
        yield
      end
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
