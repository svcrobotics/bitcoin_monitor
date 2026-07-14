# frozen_string_literal: true

require "test_helper"

class Layer1TxOutputSyncTest < ActiveSupport::TestCase
  test "accepts only durable sync statuses" do
    Layer1TxOutputSync::STATUSES.each do |status|
      record = Layer1TxOutputSync.new(
        height: 955_700 + Layer1TxOutputSync::STATUSES.index(status),
        block_hash: "a" * 64,
        status: status
      )

      assert record.valid?, "expected #{status.inspect} to be valid"
    end

    record = Layer1TxOutputSync.new(
      height: 955_710,
      block_hash: "b" * 64,
      status: "unknown"
    )

    assert_not record.valid?
    assert record.errors.added?(:status, :inclusion, value: "unknown")
  end

  test "requires one checkpoint per height" do
    Layer1TxOutputSync.create!(
      height: 955_711,
      block_hash: "c" * 64,
      status: "pending"
    )

    duplicate = Layer1TxOutputSync.new(
      height: 955_711,
      block_hash: "d" * 64,
      status: "pending"
    )

    assert_not duplicate.valid?
    assert duplicate.errors.added?(:height, :taken, value: 955_711)
  end
end
