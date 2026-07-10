# frozen_string_literal: true

require "test_helper"

class AddressUtxoProjectionBlockTest < ActiveSupport::TestCase
  test "accepts a valid pending checkpoint" do
    checkpoint =
      AddressUtxoProjectionBlock.new(
        height: 100,
        block_hash: "block-hash-100"
      )

    assert_predicate checkpoint, :valid?
  end

  test "accepts every supported status" do
    assert_equal(
      %w[
        pending
        processing
        completed
        failed
        stale
      ],
      AddressUtxoProjectionBlock::STATUSES
    )

    AddressUtxoProjectionBlock::STATUSES
      .each_with_index do |status, index|
        checkpoint =
          AddressUtxoProjectionBlock.new(
            height: 200 + index,
            block_hash: "block-hash-#{status}",
            status: status,
            completed_at:
              status == "completed" ? Time.current : nil
          )

        assert_predicate checkpoint, :valid?
      end
  end

  test "rejects an unsupported status" do
    checkpoint =
      AddressUtxoProjectionBlock.new(
        height: 300,
        block_hash: "block-hash-unknown",
        status: "unknown"
      )

    assert_not checkpoint.valid?
    assert_predicate checkpoint.errors[:status], :any?
  end

  test "rejects negative counters and amounts" do
    attributes = {
      height:
        400,
      block_hash:
        "block-hash-negative"
    }

    %i[
      attempts
      received_output_count
      spent_output_count
      received_address_count
      spent_address_count
      total_received_sats
      total_spent_sats
    ].each do |attribute|
      checkpoint =
        AddressUtxoProjectionBlock.new(
          attributes.merge(
            attribute => -1
          )
        )

      assert_not checkpoint.valid?,
        "#{attribute} should reject negative values"

      assert_predicate checkpoint.errors[attribute], :any?
    end
  end

  test "completed checkpoint requires completed_at" do
    checkpoint =
      AddressUtxoProjectionBlock.new(
        height: 500,
        block_hash: "block-hash-completed",
        status: "completed"
      )

    assert_not checkpoint.valid?
    assert_predicate checkpoint.errors[:completed_at], :any?
  end

  test "height must be unique" do
    AddressUtxoProjectionBlock.create!(
      height: 600,
      block_hash: "block-hash-600"
    )

    duplicate =
      AddressUtxoProjectionBlock.new(
        height: 600,
        block_hash: "other-block-hash-600"
      )

    assert_not duplicate.valid?
    assert_predicate duplicate.errors[:height], :any?
  end

  test "checkpoint scopes are explicit" do
    pending =
      AddressUtxoProjectionBlock.create!(
        height: 703,
        block_hash: "block-hash-pending",
        status: "pending"
      )

    failed =
      AddressUtxoProjectionBlock.create!(
        height: 702,
        block_hash: "block-hash-failed",
        status: "failed"
      )

    completed =
      AddressUtxoProjectionBlock.create!(
        height: 701,
        block_hash: "block-hash-completed",
        status: "completed",
        completed_at: Time.current
      )

    assert_equal(
      [completed],
      AddressUtxoProjectionBlock.completed.to_a
    )

    assert_equal(
      [pending, failed].sort_by(&:id),
      AddressUtxoProjectionBlock
        .pending_or_failed
        .to_a
        .sort_by(&:id)
    )

    assert_equal(
      [completed, failed, pending],
      AddressUtxoProjectionBlock.by_height.to_a
    )
  end

  test "schema exposes strict check constraints" do
    names =
      ActiveRecord::Base
        .connection
        .check_constraints(
          :address_utxo_projection_blocks
        )
        .map(&:name)

    assert_includes(
      names,
      "address_utxo_projection_blocks_status_check"
    )

    assert_includes(
      names,
      "address_utxo_projection_blocks_completed_at_check"
    )
  end
end
