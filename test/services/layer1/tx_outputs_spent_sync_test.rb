# frozen_string_literal: true

require "test_helper"

class TxOutputsSpentSyncTest < ActiveSupport::TestCase
  test "projects spent fields from cluster inputs in an idempotent batch" do
    height = 250
    txid = "4" * 64
    spending_txid = "5" * 64

    TxOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qhistory",
      amount_btc: BigDecimal("0.75"),
      block_height: 100,
      spent: false
    )

    ClusterInput.create!(
      block_height: 100,
      txid: txid,
      vout: 0,
      address: "bc1qhistory",
      amount_btc: BigDecimal("0.75"),
      spent: true,
      spent_txid: spending_txid,
      spent_block_height: height
    )

    record = Layer1TxOutputSync.create!(
      height: height,
      block_hash: "6" * 64,
      status: "pending"
    )

    result = Layer1::TxOutputsSpentSync::SyncHeight.call(
      sync_record: record,
      batch_size: 10,
      logger: Rails.logger
    )

    output = TxOutput.find_by!(txid: txid, vout: 0)
    record.reload

    assert result[:ok]
    assert_equal "synced", result[:status]
    assert output.spent?
    assert_equal spending_txid, output.spent_txid
    assert_equal height, output.spent_block_height
    assert_equal "synced", record.status
    assert_equal 0, record.remaining_rows

    second = Layer1::TxOutputsSpentSync::SyncHeight.call(
      sync_record: record,
      batch_size: 10,
      logger: Rails.logger
    )

    assert_equal 0, second[:rows_updated]
    assert_equal "synced", second[:status]
  end
end

class TxOutputsSpentSyncSchedulingTest < ActiveSupport::TestCase
  test "pending records remain eligible after more than max attempts worth of batches" do
    old_value = ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS"]
    ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS"] = "2"

    record = Layer1TxOutputSync.create!(
      height: 300,
      block_hash: "7" * 64,
      status: "pending",
      attempts: 2,
      remaining_rows: 1
    )

    assert_equal record, Layer1::TxOutputsSpentSync::NextRecord.call
  ensure
    ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS"] = old_value
  end

  test "failed records stop being eligible at max attempts" do
    old_value = ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS"]
    ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS"] = "2"

    Layer1TxOutputSync.create!(
      height: 301,
      block_hash: "8" * 64,
      status: "failed",
      attempts: 2,
      remaining_rows: 1
    )

    assert_nil Layer1::TxOutputsSpentSync::NextRecord.call
  ensure
    ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS"] = old_value
  end

  test "successful partial batches reset consecutive failures and remain eligible" do
    height = 302

    2.times do |index|
      txid = index.to_s.rjust(64, "9")

      TxOutput.create!(
        txid: txid,
        vout: 0,
        address: "bc1qbatch#{index}",
        amount_btc: BigDecimal("0.1"),
        block_height: 200,
        spent: false
      )

      ClusterInput.create!(
        block_height: 200,
        txid: txid,
        vout: 0,
        address: "bc1qbatch#{index}",
        amount_btc: BigDecimal("0.1"),
        spent: true,
        spent_txid: "a" * 64,
        spent_block_height: height
      )
    end

    record = Layer1TxOutputSync.create!(
      height: height,
      block_hash: "b" * 64,
      status: "pending",
      attempts: 0
    )

    first = Layer1::TxOutputsSpentSync::SyncHeight.call(
      sync_record: record,
      batch_size: 1,
      logger: Rails.logger
    )

    record.reload

    assert_equal "pending", first[:status]
    assert_equal 1, first[:remaining_rows]
    assert_equal 0, record.attempts
    assert_equal record, Layer1::TxOutputsSpentSync::NextRecord.call
  end

  test "selects the lowest eligible checkpoint and respects retry deadlines" do
    now = Time.current
    synced = Layer1TxOutputSync.create!(
      height: 303,
      block_hash: "c" * 64,
      status: "synced"
    )
    waiting = Layer1TxOutputSync.create!(
      height: 304,
      block_hash: "d" * 64,
      status: "failed",
      attempts: 1,
      last_attempt_at: now
    )
    eligible = Layer1TxOutputSync.create!(
      height: 305,
      block_hash: "e" * 64,
      status: "failed",
      attempts: 1,
      last_attempt_at: 1.minute.ago
    )
    pending = Layer1TxOutputSync.create!(
      height: 306,
      block_hash: "f" * 64,
      status: "pending"
    )

    claimed = Layer1::TxOutputsSpentSync::NextRecord.call

    assert_equal eligible, claimed
    assert_equal "processing", claimed.reload.status
    assert_not_nil claimed.started_at
    assert_not_nil claimed.last_attempt_at
    assert_equal "synced", synced.reload.status
    assert_equal "failed", waiting.reload.status
    assert_equal "pending", pending.reload.status
  end

  test "only reclaims processing checkpoints after their lease is stale" do
    fresh = Layer1TxOutputSync.create!(
      height: 307,
      block_hash: "1" * 64,
      status: "processing",
      last_attempt_at: 1.minute.ago
    )
    stale = Layer1TxOutputSync.create!(
      height: 308,
      block_hash: "2" * 64,
      status: "processing",
      last_attempt_at: 20.minutes.ago
    )

    claimed = Layer1::TxOutputsSpentSync::NextRecord.call

    assert_equal stale, claimed
    assert_equal "processing", fresh.reload.status
    assert_operator claimed.last_attempt_at, :>, 1.minute.ago
  end

  test "a failed batch preserves progress and increments consecutive failures" do
    record = Layer1TxOutputSync.create!(
      height: 309,
      block_hash: "3" * 64,
      status: "pending",
      attempts: 2,
      inputs_count: 8,
      matching_tx_outputs_count: 7,
      rows_updated: 5,
      remaining_rows: 2,
      last_error: "previous failure"
    )
    service = Layer1::TxOutputsSpentSync::SyncHeight.new(
      sync_record: record,
      batch_size: 1,
      logger: Rails.logger
    )
    service.define_singleton_method(:update_one_batch) do
      raise "simulated batch failure"
    end

    error = assert_raises(RuntimeError) { service.call }
    record.reload

    assert_equal "simulated batch failure", error.message
    assert_equal "failed", record.status
    assert_equal 3, record.attempts
    assert_equal 8, record.inputs_count
    assert_equal 7, record.matching_tx_outputs_count
    assert_equal 5, record.rows_updated
    assert_equal 2, record.remaining_rows
    assert_match "RuntimeError: simulated batch failure", record.last_error
  end

  test "progress after a failure clears the error without touching strict tables" do
    height = 310
    txid = "4" * 64

    TxOutput.create!(
      txid: txid,
      vout: 1,
      address: "bc1qretry",
      amount_btc: BigDecimal("0.2"),
      block_height: 200,
      spent: false
    )
    input = ClusterInput.create!(
      block_height: 200,
      txid: txid,
      vout: 1,
      address: "bc1qretry",
      amount_btc: BigDecimal("0.2"),
      spent: true,
      spent_txid: "5" * 64,
      spent_block_height: height
    )
    input_attributes = input.attributes
    record = Layer1TxOutputSync.create!(
      height: height,
      block_hash: "6" * 64,
      status: "failed",
      attempts: 3,
      rows_updated: 4,
      remaining_rows: 1,
      last_error: "old failure"
    )

    result = assert_no_queries_match(/\butxo_outputs\b/i) do
      Layer1::TxOutputsSpentSync::SyncHeight.call(
        sync_record: record,
        batch_size: 1,
        logger: Rails.logger
      )
    end
    record.reload

    assert_equal true, result[:ok]
    assert_equal "synced", record.status
    assert_equal 0, record.attempts
    assert_nil record.last_error
    assert_equal 5, record.rows_updated
    assert_equal input_attributes, input.reload.attributes
  end
end

class TxOutputsSpentSyncClaimTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Layer1TxOutputSync.delete_all
  end

  teardown do
    Layer1TxOutputSync.delete_all
  end

  test "atomically claims a checkpoint only once" do
    record = Layer1TxOutputSync.create!(
      height: 955_750,
      block_hash: "7" * 64,
      status: "pending"
    )
    ready = Queue.new
    start = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          Layer1::TxOutputsSpentSync::NextRecord.call&.id
        end
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    claimed_ids = threads.map(&:value).compact

    assert_equal [record.id], claimed_ids
    assert_equal "processing", record.reload.status
  ensure
    threads&.each { |thread| thread.join if thread.alive? }
  end
end
