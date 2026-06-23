# frozen_string_literal: true

require "test_helper"

class Layer1TxOutputProjectionBlockTest < ActiveSupport::TestCase
  test "validates required fields and status" do
    record = Layer1TxOutputProjectionBlock.new

    assert_not record.valid?
    assert record.errors.added?(:height, :blank)
    assert record.errors.added?(:block_hash, :blank)

    record.assign_attributes(
      height: 955_000,
      block_hash: "0" * 64,
      status: "unknown"
    )

    assert_not record.valid?
    assert record.errors.added?(:status, :inclusion, value: "unknown")
  end

  test "enforces unique height" do
    Layer1TxOutputProjectionBlock.create!(
      height: 955_001,
      block_hash: "1" * 64,
      status: "pending"
    )

    duplicate = Layer1TxOutputProjectionBlock.new(
      height: 955_001,
      block_hash: "2" * 64,
      status: "pending"
    )

    assert_not duplicate.valid?
    assert duplicate.errors.added?(:height, :taken, value: 955_001)
  end

  test "orders retryable projection records by height" do
    projected = Layer1TxOutputProjectionBlock.create!(
      height: 955_010,
      block_hash: "a" * 64,
      status: "projected"
    )

    high = Layer1TxOutputProjectionBlock.create!(
      height: 955_012,
      block_hash: "b" * 64,
      status: "failed"
    )

    low = Layer1TxOutputProjectionBlock.create!(
      height: 955_011,
      block_hash: "c" * 64,
      status: "pending"
    )

    assert_equal [low, high], Layer1TxOutputProjectionBlock.pending_first.to_a
    assert_equal [projected], Layer1TxOutputProjectionBlock.projected.to_a
  end

  test "rejects negative counters and values" do
    record = Layer1TxOutputProjectionBlock.new(
      height: 955_020,
      block_hash: "d" * 64,
      status: "pending",
      expected_outputs_count: -1,
      projected_outputs_count: -1,
      rows_inserted: -1,
      rows_skipped: -1,
      attempts: -1,
      expected_outputs_value_btc: -1,
      projected_outputs_value_btc: -1
    )

    assert_not record.valid?
    assert record.errors[:expected_outputs_count].any?
    assert record.errors[:projected_outputs_count].any?
    assert record.errors[:rows_inserted].any?
    assert record.errors[:rows_skipped].any?
    assert record.errors[:attempts].any?
    assert record.errors[:expected_outputs_value_btc].any?
    assert record.errors[:projected_outputs_value_btc].any?
  end
end
