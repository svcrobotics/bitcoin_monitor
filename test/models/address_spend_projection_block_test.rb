# frozen_string_literal: true

require "test_helper"

class AddressSpendProjectionBlockTest <
  ActiveSupport::TestCase

  test "accepts every supported status" do
    AddressSpendProjectionBlock::STATUSES
      .each_with_index do |status, index|
        record =
          AddressSpendProjectionBlock.new(
            height: 100 + index,
            block_hash:
              "hash-#{status}",
            status: status
          )

        assert_predicate record, :valid?
      end
  end

  test "rejects an unsupported status" do
    record =
      AddressSpendProjectionBlock.new(
        height: 200,
        block_hash: "hash-invalid",
        status: "unknown"
      )

    assert_not record.valid?
    assert_predicate record.errors[:status], :any?
  end

  test "height must be unique" do
    AddressSpendProjectionBlock.create!(
      height: 300,
      block_hash: "hash-300"
    )

    duplicate =
      AddressSpendProjectionBlock.new(
        height: 300,
        block_hash: "other-hash-300"
      )

    assert_not duplicate.valid?
    assert_predicate duplicate.errors[:height], :any?
  end

  test "completed predicate follows status" do
    completed =
      AddressSpendProjectionBlock.new(
        status: "completed"
      )

    pending =
      AddressSpendProjectionBlock.new(
        status: "pending"
      )

    assert_predicate completed, :completed?
    assert_not_predicate pending, :completed?
  end
end
