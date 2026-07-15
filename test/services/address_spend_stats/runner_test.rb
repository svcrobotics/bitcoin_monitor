# frozen_string_literal: true

require "test_helper"

module AddressSpendStats
  class RunnerTest <
    ActiveSupport::TestCase

    test "projects certified blocks sequentially and respects limit" do
      first_height = 1_610_001
      second_height = 1_610_002

      first_address =
        create_address("runner-first")

      second_address =
        create_address("runner-second")

      create_source_block(
        height: first_height
      )

      create_source_block(
        height: second_height
      )

      create_input(
        height: first_height,
        address:
          first_address.address,
        amount_btc: "0.25",
        suffix: "first"
      )

      create_input(
        height: second_height,
        address:
          second_address.address,
        amount_btc: "0.75",
        suffix: "second"
      )

      first_run =
        Runner.call(
          limit: 1,
          max_runtime_seconds: 60,
          lock: false
        )

      assert first_run[:ok]

      assert_equal(
        "limit_reached",
        first_run[:stopped_reason]
      )

      assert_equal 1,
                   first_run[:projected_blocks]

      assert_equal first_height,
                   first_run[:first_height]

      assert(
        AddressSpendProjectionBlock
          .completed
          .exists?(
            height: first_height
          )
      )

      assert_not(
        AddressSpendProjectionBlock
          .completed
          .exists?(
            height: second_height
          )
      )

      second_run =
        Runner.call(
          limit: 5,
          max_runtime_seconds: 60,
          lock: false
        )

      assert second_run[:ok]

      assert_equal(
        "empty_queue",
        second_run[:stopped_reason]
      )

      assert_equal 1,
                   second_run[:projected_blocks]

      assert_equal second_height,
                   second_run[:last_height]

      assert(
        AddressSpendProjectionBlock
          .completed
          .exists?(
            height: second_height
          )
      )
    end

    test "stops before work when runtime budget is exhausted" do
      clock_calls = 0

      clock =
        lambda do
          clock_calls += 1

          clock_calls == 1 ?
            0.0 :
            31.0
        end

      next_record =
        lambda do
          raise(
            "NextRecord should not be called"
          )
        end

      result =
        Runner.new(
          limit: 10,
          max_runtime_seconds: 30,
          lock: false,
          next_record: next_record,
          projector:
            AddressSpendStats::ProjectBlock,
          clock: clock
        ).call

      assert result[:ok]

      assert_equal(
        "runtime_budget_exceeded",
        result[:stopped_reason]
      )

      assert_equal 0,
                   result[:projected_blocks]
    end

    test "returns a structured error from the projector" do
      source =
        Struct
          .new(:height)
          .new(1_620_001)

      next_record =
        lambda do
          source
        end

      projector =
        lambda do |height:|
          raise(
            "projection failed "             "height=#{height}"
          )
        end

      result =
        Runner.new(
          limit: 1,
          max_runtime_seconds: 30,
          lock: false,
          next_record: next_record,
          projector: projector,
          clock: -> { 0.0 }
        ).call

      assert_not result[:ok]

      assert_equal(
        "error",
        result[:stopped_reason]
      )

      assert_equal 1_620_001,
                   result[:failed_height]

      assert_equal(
        "RuntimeError",
        result[:error_class]
      )

      assert_match(
        "projection failed",
        result[:error_message]
      )
    end

    private

    def create_address(suffix)
      Address.create!(
        address:
          "bc1qaddressspend#{suffix}"           "000000000000000000000"
      )
    end

    def create_source_block(height:)
      ClusterProcessedBlock.create!(
        height: height,
        block_hash:
          "runner-block-hash-#{height}",
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
          "runner-source-#{height}-#{suffix}",
        vout: 0,
        address: address,
        amount_btc:
          BigDecimal(amount_btc),
        spent: true,
        spent_txid:
          "runner-spent-#{height}-#{suffix}",
        spent_block_height:
          height
      )
    end
  end
end
