# frozen_string_literal: true

require "test_helper"

class TxOutputProjectionTest < ActiveSupport::TestCase
  class FakeRpc
    def initialize(block_hash:, block:)
      @block_hash = block_hash
      @block = block
    end

    def getblockhash(_height)
      @block_hash
    end

    def getblock(_block_hash, _verbosity)
      @block
    end
  end

  test "register creates a pending projection checkpoint" do
    record = Layer1::TxOutputProjection::Register.call(
      height: 955_100,
      block_hash: "1" * 64,
      expected_outputs_count: 2,
      expected_outputs_value_btc: BigDecimal("1.25")
    )

    assert record.persisted?
    assert_equal 955_100, record.height
    assert_equal "1" * 64, record.block_hash
    assert_equal "pending", record.status
    assert_equal 2, record.expected_outputs_count
    assert_equal BigDecimal("1.25"), record.expected_outputs_value_btc
  end

  test "register resets checkpoint when block hash changes" do
    record = Layer1TxOutputProjectionBlock.create!(
      height: 955_101,
      block_hash: "2" * 64,
      status: "failed",
      expected_outputs_count: 1,
      expected_outputs_value_btc: BigDecimal("0.5"),
      projected_outputs_count: 1,
      projected_outputs_value_btc: BigDecimal("0.5"),
      rows_inserted: 1,
      rows_skipped: 0,
      attempts: 3,
      duration_ms: 100,
      started_at: Time.current,
      last_attempt_at: Time.current,
      completed_at: Time.current,
      last_error: "old error",
      metadata: { old: true }
    )

    updated = Layer1::TxOutputProjection::Register.call(
      height: record.height,
      block_hash: "3" * 64,
      expected_outputs_count: 2,
      expected_outputs_value_btc: BigDecimal("0.75")
    )

    assert_equal record.id, updated.id
    assert_equal "3" * 64, updated.block_hash
    assert_equal "pending", updated.status
    assert_equal 2, updated.expected_outputs_count
    assert_equal BigDecimal("0.75"), updated.expected_outputs_value_btc
    assert_equal 0, updated.projected_outputs_count
    assert_equal 0, updated.rows_inserted
    assert_equal 0, updated.attempts
    assert_nil updated.completed_at
    assert_nil updated.last_error
    assert_equal({}, updated.metadata)
  end

  test "next record returns the oldest retryable checkpoint" do
    old_value = ENV["TX_OUTPUT_PROJECTION_MAX_ATTEMPTS"]
    old_stale =
      ENV["TX_OUTPUT_PROJECTION_PROCESSING_STALE_AFTER_SECONDS"]

    ENV["TX_OUTPUT_PROJECTION_MAX_ATTEMPTS"] = "2"
    ENV["TX_OUTPUT_PROJECTION_PROCESSING_STALE_AFTER_SECONDS"] = "60"

    projected = Layer1TxOutputProjectionBlock.create!(
      height: 955_110,
      block_hash: "4" * 64,
      status: "projected"
    )

    too_failed = Layer1TxOutputProjectionBlock.create!(
      height: 955_111,
      block_hash: "5" * 64,
      status: "failed",
      attempts: 2
    )

    retryable = Layer1TxOutputProjectionBlock.create!(
      height: 955_112,
      block_hash: "6" * 64,
      status: "failed",
      attempts: 1
    )

    fresh_processing = Layer1TxOutputProjectionBlock.create!(
      height: 955_113,
      block_hash: "7" * 64,
      status: "processing",
      attempts: 1,
      last_attempt_at: 30.seconds.ago
    )

    stale_processing = Layer1TxOutputProjectionBlock.create!(
      height: 955_114,
      block_hash: "8" * 64,
      status: "processing",
      attempts: 1,
      last_attempt_at: 2.minutes.ago
    )

    pending = Layer1TxOutputProjectionBlock.create!(
      height: 955_115,
      block_hash: "9" * 64,
      status: "pending"
    )

    assert_equal retryable, Layer1::TxOutputProjection::NextRecord.call
    assert_not_equal projected, Layer1::TxOutputProjection::NextRecord.call
    assert_not_equal too_failed, Layer1::TxOutputProjection::NextRecord.call
    assert_not_equal fresh_processing, Layer1::TxOutputProjection::NextRecord.call
    assert_not_equal pending, Layer1::TxOutputProjection::NextRecord.call

    retryable.update!(
      attempts: 2
    )

    assert_equal stale_processing, Layer1::TxOutputProjection::NextRecord.call
    assert_not_equal pending, Layer1::TxOutputProjection::NextRecord.call
  ensure
    ENV["TX_OUTPUT_PROJECTION_MAX_ATTEMPTS"] = old_value
    ENV[
      "TX_OUTPUT_PROJECTION_PROCESSING_STALE_AFTER_SECONDS"
    ] = old_stale
  end

  test "projects tx outputs from bitcoin core idempotently" do
    block_hash = "8" * 64
    block = block_payload(
      block_hash: block_hash,
      outputs: [
        output_payload(0, "bc1qprojection", "0.75"),
        output_payload(1, nil, "0.50")
      ]
    )

    record = Layer1TxOutputProjectionBlock.create!(
      height: 955_120,
      block_hash: block_hash,
      status: "pending",
      expected_outputs_count: 2,
      expected_outputs_value_btc: BigDecimal("1.25")
    )

    result = Layer1::TxOutputProjection::ProjectHeight.call(
      projection_block: record,
      rpc: FakeRpc.new(block_hash: block_hash, block: block),
      batch_size: 1,
      logger: Rails.logger
    )

    record.reload

    assert result[:ok]
    assert_equal "projected", result[:status]
    assert_equal 2, result[:projected_outputs_count]
    assert_equal BigDecimal("1.25"), result[:projected_outputs_value_btc]
    assert_equal 2, result[:rows_inserted]
    assert_equal 0, result[:rows_skipped]
    assert_equal "projected", record.status
    assert_equal 2, record.projected_outputs_count
    assert_equal BigDecimal("1.25"), record.projected_outputs_value_btc

    first_output = TxOutput.find_by!(txid: "a" * 64, vout: 0)
    second_output = TxOutput.find_by!(txid: "a" * 64, vout: 1)

    assert_equal "bc1qprojection", first_output.address
    assert_equal BigDecimal("0.75"), first_output.amount_btc
    assert_equal 955_120, first_output.block_height
    assert_equal block_hash, first_output.block_hash
    assert_not first_output.spent?
    assert_nil second_output.address
    assert_equal BigDecimal("0.50"), second_output.amount_btc

    second = Layer1::TxOutputProjection::ProjectHeight.call(
      projection_block: record,
      rpc: FakeRpc.new(block_hash: block_hash, block: block),
      batch_size: 10,
      logger: Rails.logger
    )

    assert_equal 0, second[:rows_inserted]
    assert_equal 2, second[:rows_skipped]
    assert_equal 2, TxOutput.where(block_height: 955_120).count
  end

  test "fails checkpoint without writing when bitcoin core hash mismatches" do
    record = Layer1TxOutputProjectionBlock.create!(
      height: 955_130,
      block_hash: "9" * 64,
      status: "pending",
      expected_outputs_count: 1,
      expected_outputs_value_btc: BigDecimal("0.1")
    )

    assert_raises(RuntimeError) do
      Layer1::TxOutputProjection::ProjectHeight.call(
        projection_block: record,
        rpc: FakeRpc.new(
          block_hash: "f" * 64,
          block: block_payload(
            block_hash: "f" * 64,
            outputs: [output_payload(0, "bc1qmismatch", "0.1")]
          )
        ),
        logger: Rails.logger
      )
    end

    record.reload

    assert_equal "failed", record.status
    assert_equal 1, record.attempts
    assert_match "block hash mismatch", record.last_error
    assert_equal 0, TxOutput.where(block_height: 955_130).count
  end

  test "fails checkpoint when projected facts differ from expected facts" do
    block_hash = "b" * 64
    record = Layer1TxOutputProjectionBlock.create!(
      height: 955_140,
      block_hash: block_hash,
      status: "pending",
      expected_outputs_count: 2,
      expected_outputs_value_btc: BigDecimal("1.0")
    )

    assert_raises(RuntimeError) do
      Layer1::TxOutputProjection::ProjectHeight.call(
        projection_block: record,
        rpc: FakeRpc.new(
          block_hash: block_hash,
          block: block_payload(
            block_hash: block_hash,
            outputs: [output_payload(0, "bc1qshort", "1.0")]
          )
        ),
        logger: Rails.logger
      )
    end

    record.reload

    assert_equal "failed", record.status
    assert_match "projected facts mismatch", record.last_error
    assert_equal 0, TxOutput.where(block_height: 955_140).count
  end

  private

  def block_payload(block_hash:, outputs:)
    {
      "hash" => block_hash,
      "time" => 1_717_171_717,
      "tx" => [
        {
          "txid" => "a" * 64,
          "vout" => outputs
        }
      ]
    }
  end

  def output_payload(n, address, value)
    script = {}
    script["address"] = address if address

    {
      "n" => n,
      "value" => value,
      "scriptPubKey" => script
    }
  end
end
