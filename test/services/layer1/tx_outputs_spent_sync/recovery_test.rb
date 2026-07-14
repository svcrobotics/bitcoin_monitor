# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Layer1
  module TxOutputsSpentSync
    class RecoveryTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      TEST_HEIGHTS = (957_100..957_199)

      setup do
        @previous_stale_after = ENV["TX_OUTPUTS_SPENT_SYNC_STALE_AFTER_SECONDS"]
        ENV["TX_OUTPUTS_SPENT_SYNC_STALE_AFTER_SECONDS"] = "60"
        Layer1TxOutputSync.where(height: TEST_HEIGHTS).delete_all
      end

      teardown do
        Layer1TxOutputSync.where(height: TEST_HEIGHTS).delete_all
        if @previous_stale_after.nil?
          ENV.delete("TX_OUTPUTS_SPENT_SYNC_STALE_AFTER_SECONDS")
        else
          ENV["TX_OUTPUTS_SPENT_SYNC_STALE_AFTER_SECONDS"] = @previous_stale_after
        end
      end

      test "requeues a stale checkpoint without changing durable progress" do
        record = create_checkpoint(
          height: 957_100,
          status: "processing",
          inputs_count: 12,
          matching_tx_outputs_count: 11,
          rows_updated: 7,
          remaining_rows: 4,
          attempts: 3,
          duration_ms: 90,
          started_at: 2.hours.ago,
          last_attempt_at: 2.hours.ago,
          last_error: "previous failure"
        )
        preserved_attributes = record.attributes.except("status")

        result = SyncHeight.stub(
          :call,
          ->(*) { flunk("Recovery must not execute SyncHeight") }
        ) do
          Recovery.call(limit: 10)
        end

        assert_equal true, result[:ok]
        assert_equal 1, result[:recovered]
        assert_equal [record.id], result[:checkpoint_ids]
        assert_equal [record.height], result[:heights]
        assert_equal "pending", record.reload.status
        assert_equal preserved_attributes, record.attributes.except("status")
        assert_equal 3, record.attempts

        second = Recovery.call(limit: 10)

        assert_equal 0, second[:recovered]
        assert_empty second[:checkpoint_ids]
        assert_empty second[:heights]
      end

      test "leaves a fresh processing checkpoint untouched" do
        record = create_checkpoint(
          height: 957_101,
          status: "processing",
          started_at: Time.current,
          last_attempt_at: Time.current
        )
        original_attributes = record.attributes

        result = Recovery.call(limit: 10)

        assert_equal 0, result[:recovered]
        assert_equal original_attributes, record.reload.attributes
      end

      test "recovers stale checkpoints in deterministic height order up to the limit" do
        high = stale_checkpoint(957_105)
        low = stale_checkpoint(957_103)
        middle = stale_checkpoint(957_104)

        result = Recovery.call(limit: 2)

        assert_equal 2, result[:recovered]
        assert_equal [low.id, middle.id], result[:checkpoint_ids]
        assert_equal [957_103, 957_104], result[:heights]
        assert_equal "pending", low.reload.status
        assert_equal "pending", middle.reload.status
        assert_equal "processing", high.reload.status
      end

      test "skips a checkpoint locked by another transaction" do
        record = stale_checkpoint(957_106)
        locked = Queue.new
        release = Queue.new
        thread = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Layer1TxOutputSync.transaction do
              Layer1TxOutputSync.lock.find(record.id)
              locked << true
              release.pop
            end
          end
        end

        locked.pop
        result = Recovery.call(limit: 10)

        assert_equal 0, result[:recovered]
        assert_equal "processing", record.reload.status

        release << true
        thread.join
        thread = nil

        retry_result = Recovery.call(limit: 10)

        assert_equal [record.id], retry_result[:checkpoint_ids]
        assert_equal "pending", record.reload.status
      ensure
        release << true if thread&.alive?
        thread&.join
      end

      test "has no Redis Sidekiq worker lock or engine dependency" do
        source = File.read(
          Rails.root.join(
            "app/services/layer1/tx_outputs_spent_sync/recovery.rb"
          )
        )

        refute_match(/\bRedis\b/, source)
        refute_match(/\bSidekiq\b/, source)
        refute_match(/\bLOCK_KEY\b/, source)
        refute_match(/\bTxOutputsSpentSyncJob\b/, source)
        refute_match(/\bSyncHeight\b/, source)
        refute_match(/perform_(?:async|in)/, source)
      end

      test "propagates PostgreSQL errors" do
        error = ActiveRecord::StatementInvalid.new("database unavailable")

        raised = assert_raises(ActiveRecord::StatementInvalid) do
          Layer1TxOutputSync.stub(:transaction, -> { raise error }) do
            Recovery.call(limit: 1)
          end
        end

        assert_same error, raised
      end

      private

      def stale_checkpoint(height)
        create_checkpoint(
          height: height,
          status: "processing",
          started_at: 2.hours.ago,
          last_attempt_at: 2.hours.ago
        )
      end

      def create_checkpoint(height:, status:, **attributes)
        Layer1TxOutputSync.create!(
          {
            height: height,
            block_hash: height.to_s.rjust(64, "0"),
            status: status
          }.merge(attributes)
        )
      end
    end
  end
end
