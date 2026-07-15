# frozen_string_literal: true

require "test_helper"

module AddressSpendStats
  class ProjectBlockTest <
    ActiveSupport::TestCase

    test "projects several inputs for one address" do
      height = 1_500_001
      address = create_address("one")

      create_processed_block(
        height: height
      )

      create_input(
        height: height,
        address: address.address,
        amount_btc: "1.25",
        suffix: "a"
      )

      create_input(
        height: height,
        address: address.address,
        amount_btc: "0.75",
        suffix: "b"
      )

      result =
        ProjectBlock.call(
          height: height
        )

      stat =
        AddressSpendStat.find_by!(
          address: address.address
        )

      assert_equal 200_000_000,
                   stat.total_sent_sats

      assert_equal 2,
                   stat.spent_inputs_count

      assert_equal height,
                   stat.first_spent_height

      assert_equal height,
                   stat.last_spent_height

      assert_equal height,
                   stat.source_height

      assert_equal 2,
                   result[:input_count]

      assert_equal 1,
                   result[:address_count]

      assert_equal 200_000_000,
                   result[:total_sent_sats]

      assert_not result[:idempotent]

      checkpoint =
        AddressSpendProjectionBlock
          .find_by!(
            height: height
          )

      assert_predicate checkpoint, :completed?
    end

    test "projects several addresses" do
      height = 1_500_002

      first =
        create_address("first")

      second =
        create_address("second")

      create_processed_block(
        height: height
      )

      create_input(
        height: height,
        address: first.address,
        amount_btc: "0.10",
        suffix: "first"
      )

      create_input(
        height: height,
        address: second.address,
        amount_btc: "0.20",
        suffix: "second"
      )

      result =
        ProjectBlock.call(
          height: height
        )

      assert_equal 2,
                   result[:address_count]

      assert_equal 30_000_000,
                   result[:total_sent_sats]

      assert_equal 2,
                   AddressSpendStat
                     .where(
                       address: [
                         first.address,
                         second.address
                       ]
                     )
                     .count
    end

    test "retry is idempotent" do
      height = 1_500_003
      address = create_address("retry")

      create_processed_block(
        height: height
      )

      create_input(
        height: height,
        address: address.address,
        amount_btc: "0.50",
        suffix: "retry"
      )

      first =
        ProjectBlock.call(
          height: height
        )

      second =
        ProjectBlock.call(
          height: height
        )

      stat =
        AddressSpendStat.find_by!(
          address: address.address
        )

      assert_not first[:idempotent]
      assert second[:idempotent]

      assert_equal 50_000_000,
                   stat.total_sent_sats

      assert_equal 1,
                   stat.spent_inputs_count

      assert_equal 1,
                   second[:attempts]
    end

    test "accumulates different projected heights" do
      first_height = 1_500_004
      second_height = 1_500_005
      address = create_address("sequential")

      create_processed_block(
        height: first_height
      )

      create_processed_block(
        height: second_height
      )

      create_input(
        height: first_height,
        address: address.address,
        amount_btc: "1.00",
        suffix: "sequential-a"
      )

      create_input(
        height: second_height,
        address: address.address,
        amount_btc: "0.50",
        suffix: "sequential-b"
      )

      ProjectBlock.call(
        height: first_height
      )

      ProjectBlock.call(
        height: second_height
      )

      stat =
        AddressSpendStat.find_by!(
          address: address.address
        )

      assert_equal 150_000_000,
                   stat.total_sent_sats

      assert_equal 2,
                   stat.spent_inputs_count

      assert_equal first_height,
                   stat.first_spent_height

      assert_equal second_height,
                   stat.last_spent_height

      assert_equal second_height,
                   stat.source_height
    end

    test "rejects a checkpoint hash conflict" do
      height = 1_500_006

      create_processed_block(
        height: height,
        block_hash: "new-hash"
      )

      AddressSpendProjectionBlock.create!(
        height: height,
        block_hash: "old-hash",
        status: "completed",
        completed_at: Time.current
      )

      assert_raises(
        ProjectBlock::BlockHashMismatch
      ) do
        ProjectBlock.call(
          height: height
        )
      end

      assert_equal(
        "old-hash",
        AddressSpendProjectionBlock
          .find_by!(
            height: height
          )
          .block_hash
      )
    end

    test "projects an address absent from addresses" do
      height = 1_500_007

      raw_address =
        "bc1qaddressspendmissing" \
        "00000000000000000000000"

      create_processed_block(
        height: height
      )

      create_input(
        height: height,
        address: raw_address,
        amount_btc: "0.75",
        suffix: "missing"
      )

      result =
        ProjectBlock.call(
          height: height
        )

      stat =
        AddressSpendStat.find_by!(
          address:
            raw_address
        )

      assert_equal(
        75_000_000,
        stat.total_sent_sats
      )

      assert_equal(
        1,
        stat.spent_inputs_count
      )

      assert_equal(
        "completed",
        result[:status]
      )

      assert_not(
        Address.exists?(
          address:
            raw_address
        )
      )
    end

    test "retries a failed checkpoint without double counting" do
      height = 1_500_010

      raw_address =
        "bc1qaddressspendretryfailed" \
        "000000000000000000000"

      create_processed_block(
        height: height
      )

      input =
        create_input(
          height: height,
          address: raw_address,
          amount_btc: "0.40",
          suffix: "retry-failed"
        )

      input.update_column(
        :amount_btc,
        BigDecimal("-0.40")
      )

      assert_raises(
        ProjectBlock::InvalidAmount
      ) do
        ProjectBlock.call(
          height: height
        )
      end

      checkpoint =
        AddressSpendProjectionBlock
          .find_by!(
            height: height
          )

      assert_equal(
        "failed",
        checkpoint.status
      )

      assert_equal(
        1,
        checkpoint.attempts
      )

      assert_not(
        AddressSpendStat.exists?(
          address:
            raw_address
        )
      )

      input.update_column(
        :amount_btc,
        BigDecimal("0.40")
      )

      result =
        ProjectBlock.call(
          height: height
        )

      assert_equal(
        "completed",
        result[:status]
      )

      assert_equal(
        2,
        result[:attempts]
      )

      stat =
        AddressSpendStat.find_by!(
          address:
            raw_address
        )

      assert_equal(
        40_000_000,
        stat.total_sent_sats
      )

      assert_equal(
        1,
        stat.spent_inputs_count
      )
    end

    test "requires a processed Cluster checkpoint" do
      height = 1_500_008

      assert_raises(
        ProjectBlock::SourceUnavailable
      ) do
        ProjectBlock.call(
          height: height
        )
      end

      assert_not(
        AddressSpendProjectionBlock.exists?(
          height: height
        )
      )
    end

    test "completes an empty certified block" do
      height = 1_500_009

      create_processed_block(
        height: height
      )

      result =
        ProjectBlock.call(
          height: height
        )

      assert_equal 0,
                   result[:input_count]

      assert_equal 0,
                   result[:address_count]

      assert_equal 0,
                   result[:total_sent_sats]

      assert_equal(
        "completed",
        result[:status]
      )
    end

    private

    def create_address(suffix)
      Address.create!(
        address:
          "bc1qaddressspend#{suffix}"           "000000000000000000000000"
      )
    end

    def create_processed_block(
      height:,
      block_hash: nil
    )
      ClusterProcessedBlock.create!(
        height: height,
        block_hash:
          block_hash ||
          "block-hash-#{height}",
        status: "processed",
        scan_result: {},
        cleanup_result: {},
        audit_result: {},
        stage_timings: {},
        processed_at: Time.current
      )
    end

    def create_input(
      height:,
      address:,
      amount_btc:,
      suffix:
    )
      ClusterInput.create!(
        block_height:
          height - 10,

        txid:
          "source-txid-#{height}-#{suffix}",

        vout:
          0,

        address:
          address,

        amount_btc:
          BigDecimal(amount_btc),

        spent:
          true,

        spent_txid:
          "spent-txid-#{height}-#{suffix}",

        spent_block_height:
          height
      )
    end
  end
end
