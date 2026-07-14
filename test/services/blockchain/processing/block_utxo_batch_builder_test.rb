# frozen_string_literal: true

require "test_helper"

module Blockchain
  module Processing
    class BlockUtxoBatchBuilderTest < ActiveSupport::TestCase
      BlockBuffer = Struct.new(:height, :block_hash)

      class NullLogger
        def info(*) = nil
      end

      test "uses the verbosity 3 prevout as the strict spent-output fact" do
        previous_txid = "a" * 64
        spending_txid = "b" * 64
        prevout = {
          "generated" => false,
          "height" => 899_999,
          "value" => 1.25,
          "scriptPubKey" => { "address" => "bc1qstrictprevout" }
        }

        result = assert_no_queries do
          builder(strict_prevout: true).call(
            block_with_input(
              "txid" => previous_txid,
              "vout" => 2,
              "prevout" => prevout
            ),
            block_buffer
          )
        end

        assert_equal 1, result[:input_count]
        assert_equal 1, result[:prevout_found_count]
        assert_equal 0, result[:prevout_missing_count]
        assert_equal 1, result[:spent_rows].size
        assert_equal(
          {
            txid: previous_txid,
            vout: 2,
            spent: true,
            spent_txid: spending_txid,
            spent_block_height: 900_000,
            prevout_address: "bc1qstrictprevout",
            prevout_amount_btc: 1.25,
            prevout_block_height: 899_999,
            prevout_generated: false
          },
          result[:spent_rows].first.except(:updated_at)
        )
      end

      test "counts an absent prevout without creating a spent row" do
        result = builder(strict_prevout: false).call(
          block_with_input("txid" => "a" * 64, "vout" => 2),
          block_buffer
        )

        assert_equal 1, result[:input_count]
        assert_equal 0, result[:prevout_found_count]
        assert_equal 1, result[:prevout_missing_count]
        assert_empty result[:spent_rows]
      end

      test "rejects an absent prevout in strict mode" do
        error = assert_raises(RuntimeError) do
          builder(strict_prevout: true).call(
            block_with_input("txid" => "a" * 64, "vout" => 2),
            block_buffer
          )
        end

        assert_includes error.message, "missing prevout height=900000"
        assert_includes error.message, "input_txid=#{"a" * 64} input_vout=2"
      end

      test "does not require a prevout for a coinbase input" do
        result = builder(strict_prevout: true).call(
          block_with_input("coinbase" => "03a0bb0d"),
          block_buffer
        )

        assert_equal 1, result[:input_count]
        assert_equal 0, result[:prevout_found_count]
        assert_equal 0, result[:prevout_missing_count]
        assert_empty result[:spent_rows]
      end

      private

      def builder(strict_prevout:)
        BlockUtxoBatchBuilder.new(
          prevout_cache: {},
          logger: NullLogger.new,
          strict_prevout: strict_prevout
        )
      end

      def block_buffer
        BlockBuffer.new(900_000, "block-hash")
      end

      def block_with_input(input)
        {
          "time" => 1_720_000_000,
          "tx" => [
            {
              "txid" => "b" * 64,
              "vin" => [input],
              "vout" => []
            }
          ]
        }
      end
    end
  end
end
