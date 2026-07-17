# frozen_string_literal: true

require "test_helper"

module Layer1
  module TxOutputProjection
    class RecoveryTest < ActiveSupport::TestCase
      test "finalizes stale processing block already fully inserted" do
        height = 955_501
        txid = "a" * 64

        record =
          Layer1TxOutputProjectionBlock.create!(
            height: height,
            block_hash: "1" * 64,
            status: "processing",
            expected_outputs_count: 1,
            expected_outputs_value_btc: BigDecimal("0.5"),
            started_at: 2.hours.ago,
            last_attempt_at: 2.hours.ago
          )

        TxOutput.create!(
          txid: txid,
          vout: 0,
          address: "bc1qcomplete",
          amount_btc: BigDecimal("0.5"),
          block_height: height,
          block_hash: record.block_hash,
          spent: false
        )

        result = Recovery.call(limit: 1)

        record.reload

        assert_equal true, result[:ok]
        assert_equal 1, result[:finalized]
        assert_equal "projected", record.status
        assert_equal 1, record.attempts
        assert_equal 1, record.projected_outputs_count
        assert_equal 0, record.rows_inserted
        assert_equal 1, record.rows_skipped
        assert_not_nil record.completed_at
      ensure
        Sidekiq.redis { |redis| redis.del(Recovery::STATUS_KEY) }
      end

      test "retries stale partial block without deleting existing rows" do
        height = 955_502
        record =
          Layer1TxOutputProjectionBlock.create!(
            height: height,
            block_hash: "2" * 64,
            status: "processing",
            expected_outputs_count: 2,
            expected_outputs_value_btc: BigDecimal("1.0"),
            started_at: 2.hours.ago,
            last_attempt_at: 2.hours.ago
          )

        TxOutput.create!(
          txid: "b" * 64,
          vout: 0,
          amount_btc: BigDecimal("0.5"),
          block_height: height,
          block_hash: record.block_hash,
          spent: false
        )

        called = false

        with_stubbed(ProjectHeight, :call, ->(projection_block:, **_kwargs) {
          called = true
          projection_block.update!(
            status: "projected",
            projected_outputs_count: 2,
            projected_outputs_value_btc: BigDecimal("1.0"),
            rows_inserted: 1,
            rows_skipped: 1,
            completed_at: Time.current
          )
          { ok: true, status: "projected" }
        }) do
          result = Recovery.call(limit: 1)

          assert called
          assert_equal 1, result[:retried]
          assert_equal 1, result[:partial]
          assert_equal 1, TxOutput.where(block_height: height).count
        end
      ensure
        Sidekiq.redis { |redis| redis.del(Recovery::STATUS_KEY) }
      end

      test "does not recover while projection lock is present" do
        Layer1TxOutputProjectionBlock.create!(
          height: 955_503,
          block_hash: "3" * 64,
          status: "processing",
          started_at: 2.hours.ago,
          last_attempt_at: 2.hours.ago
        )

        Sidekiq.redis do |redis|
          redis.set(Layer1::TxOutputProjectionJob::LOCK_KEY, "token", ex: 60)
        end

        result = Recovery.call(limit: 1)

        assert_equal true, result[:skipped_active]
        assert_equal 0, result[:checked]
      ensure
        Sidekiq.redis do |redis|
          redis.del(Recovery::STATUS_KEY)
          redis.del(Layer1::TxOutputProjectionJob::LOCK_KEY)
        end
      end

      private

      def with_stubbed(object, method_name, value)
        original = object.method(method_name)
        replacement = value.respond_to?(:call) ? value : ->(*_args, **_kwargs) { value }

        object.define_singleton_method(method_name, &replacement)

        yield
      ensure
        object.define_singleton_method(method_name) do |*args, **kwargs, &block|
          original.call(*args, **kwargs, &block)
        end
      end
    end
  end
end
