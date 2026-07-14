# frozen_string_literal: true

require "test_helper"

module Layer1
  module TxOutputsSpentSync
    class WorkAvailableTest < ActiveSupport::TestCase
      test "reports pending work without claiming it" do
        record = create_checkpoint(status: "pending")
        original_attributes = record.attributes

        result = assert_no_queries_match(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) do
          2.times.map { WorkAvailable.call }
        end

        assert_equal [true, true], result
        assert_equal original_attributes, record.reload.attributes
        assert_equal record, NextRecord.call
        assert_equal "processing", record.reload.status
      end

      test "reports a failed checkpoint whose retry deadline has arrived" do
        record = create_checkpoint(
          status: "failed",
          attempts: 1,
          last_attempt_at: 1.hour.ago
        )

        assert_equal true, WorkAvailable.call
        assert_equal "failed", record.reload.status
      end

      test "reports a stale processing checkpoint" do
        record = create_checkpoint(
          status: "processing",
          last_attempt_at: 1.hour.ago
        )

        assert_equal true, WorkAvailable.call
        assert_equal "processing", record.reload.status
      end

      test "does not report synced checkpoints" do
        create_checkpoint(status: "synced")

        assert_equal false, WorkAvailable.call
      end

      test "does not report a failed checkpoint before its retry deadline" do
        record = create_checkpoint(
          status: "failed",
          attempts: 1,
          last_attempt_at: 1.hour.from_now
        )

        assert_equal false, WorkAvailable.call
        assert_equal "failed", record.reload.status
      end

      test "does not report a processing checkpoint with a live claim" do
        record = create_checkpoint(
          status: "processing",
          last_attempt_at: Time.current
        )

        assert_equal false, WorkAvailable.call
        assert_equal "processing", record.reload.status
      end

      private

      def create_checkpoint(status:, **attributes)
        Layer1TxOutputSync.create!(
          {
            height: 956_000,
            block_hash: "a" * 64,
            status: status
          }.merge(attributes)
        )
      end
    end
  end
end
