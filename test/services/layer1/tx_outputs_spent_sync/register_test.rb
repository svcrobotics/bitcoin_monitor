# frozen_string_literal: true

require "test_helper"

module Layer1
  module TxOutputsSpentSync
    class RegisterTest < ActiveSupport::TestCase
      test "creates one pending checkpoint" do
        record = Register.call(
          height: 955_720,
          block_hash: "1" * 64
        )

        assert record.persisted?
        assert_equal "pending", record.status
        assert_equal 955_720, record.height
        assert_equal "1" * 64, record.block_hash
        assert_equal 1, Layer1TxOutputSync.where(height: record.height).count
      end

      test "preserves progress for the same height and hash" do
        record = Layer1TxOutputSync.create!(
          height: 955_721,
          block_hash: "2" * 64,
          status: "processing",
          inputs_count: 12,
          matching_tx_outputs_count: 11,
          rows_updated: 7,
          remaining_rows: 4,
          attempts: 2,
          duration_ms: 90,
          started_at: 2.minutes.ago,
          last_attempt_at: 1.minute.ago,
          last_error: "retry"
        )
        expected_attributes = record.attributes.except("updated_at")

        registered = Register.call(
          height: record.height,
          block_hash: record.block_hash
        )

        assert_equal record.id, registered.id
        assert_equal expected_attributes, registered.reload.attributes.except("updated_at")
        assert_equal 1, Layer1TxOutputSync.where(height: record.height).count
      end

      test "preserves a synced checkpoint for the same hash" do
        completed_at = 1.minute.ago
        record = Layer1TxOutputSync.create!(
          height: 955_722,
          block_hash: "3" * 64,
          status: "synced",
          inputs_count: 5,
          matching_tx_outputs_count: 5,
          rows_updated: 5,
          remaining_rows: 0,
          completed_at: completed_at
        )

        registered = Register.call(
          height: record.height,
          block_hash: record.block_hash
        )

        assert_equal record.id, registered.id
        assert_equal "synced", registered.status
        assert_equal 5, registered.rows_updated
        assert_equal completed_at.to_i, registered.completed_at.to_i
        assert_equal 1, Layer1TxOutputSync.where(height: record.height).count
      end

      test "resets all progress when the block hash changes" do
        record = Layer1TxOutputSync.create!(
          height: 955_723,
          block_hash: "4" * 64,
          status: "failed",
          inputs_count: 9,
          matching_tx_outputs_count: 8,
          rows_updated: 6,
          remaining_rows: 2,
          attempts: 3,
          duration_ms: 120,
          started_at: 3.minutes.ago,
          last_attempt_at: 2.minutes.ago,
          completed_at: 1.minute.ago,
          last_error: "old failure"
        )

        registered = Register.call(
          height: record.height,
          block_hash: "5" * 64
        )

        assert_equal record.id, registered.id
        assert_equal "5" * 64, registered.block_hash
        assert_equal "pending", registered.status
        assert_equal 0, registered.inputs_count
        assert_equal 0, registered.matching_tx_outputs_count
        assert_equal 0, registered.rows_updated
        assert_nil registered.remaining_rows
        assert_equal 0, registered.attempts
        assert_nil registered.duration_ms
        assert_nil registered.started_at
        assert_nil registered.last_attempt_at
        assert_nil registered.completed_at
        assert_nil registered.last_error
        assert_equal 1, Layer1TxOutputSync.where(height: record.height).count
      end
    end
  end
end
