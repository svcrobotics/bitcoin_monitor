# frozen_string_literal: true

require "test_helper"

class ClusterTransactionProjectionBlockTest < ActiveSupport::TestCase
  test "contracts projected state and unique nonnegative height" do
    block = ClusterTransactionProjectionBlock.new(
      block_height: 9_000_003, block_hash: "hash", status: "projected",
      completed_at: Time.current
    )
    assert block.valid?
    assert block.projected?
    assert_equal %w[pending processing projected failed stale],
      ClusterTransactionProjectionBlock::STATUSES

    assert_not block.dup.tap { |copy| copy.completed_at = nil }.valid?
    assert_not block.dup.tap { |copy| copy.block_height = -1 }.valid?

    block.save!
    assert_raises(ActiveRecord::RecordInvalid) do
      ClusterTransactionProjectionBlock.create!(
        block_height: block.block_height, block_hash: "other", status: "pending"
      )
    end
  end
end
