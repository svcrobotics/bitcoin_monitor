# frozen_string_literal: true

require "active_support/test_case"
require_relative "../../../app/services/address_utxo_stats/block_delta_builder"

module AddressUtxoStats
  class BlockDeltaBuilderTest < ActiveSupport::TestCase
    HEIGHT = 100

    test "builds a delta for a live received output" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-live",
              vout: 0,
              address: "bc1qlive",
              amount_btc: "0.00000001"
            )
          ]
        )

      assert_equal 1, result[:received_output_count]
      assert_equal 0, result[:spent_output_count]
      assert_equal 1, result[:total_received_sats]
      assert_equal 1, result[:balance_delta_sats]
      assert_empty result[:anomalies]

      assert_equal(
        {
          address: "bc1qlive",
          received_sats_delta: 1,
          spent_sats_delta: 0,
          balance_sats_delta: 1,
          live_utxo_count_delta: 1,
          received_output_count_delta: 1,
          first_received_height_candidate: HEIGHT,
          last_received_height_candidate: HEIGHT,
          last_changed_height: HEIGHT
        },
        result[:deltas].first
      )
    end

    test "builds a delta for an old utxo spent in the block" do
      result =
        build_delta(
          cluster_inputs: [
            input(
              txid: "tx-old",
              vout: 0,
              address: "bc1qspent",
              amount_btc: "1.23456789",
              block_height: 80,
              spent_block_height: HEIGHT
            )
          ]
        )

      assert_equal 0, result[:received_output_count]
      assert_equal 1, result[:spent_output_count]
      assert_equal 123_456_789, result[:total_spent_sats]
      assert_equal(-123_456_789, result[:balance_delta_sats])
      assert_empty result[:anomalies]

      delta =
        result[:deltas].first

      assert_equal "bc1qspent", delta[:address]
      assert_equal 0, delta[:received_sats_delta]
      assert_equal 123_456_789, delta[:spent_sats_delta]
      assert_equal(-123_456_789, delta[:balance_sats_delta])
      assert_equal(-1, delta[:live_utxo_count_delta])
      assert_nil delta[:first_received_height_candidate]
      assert_nil delta[:last_received_height_candidate]
    end

    test "aggregates multiple received outputs for the same address" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-a",
              vout: 0,
              address: "bc1qsame",
              amount_btc: "0.00000002"
            ),
            utxo(
              txid: "tx-b",
              vout: 0,
              address: "bc1qsame",
              amount_btc: "0.00000003"
            )
          ]
        )

      assert_equal 1, result[:addresses_touched]
      assert_equal 2, result[:received_output_count]
      assert_equal 5, result[:total_received_sats]

      delta =
        result[:deltas].first

      assert_equal 5, delta[:received_sats_delta]
      assert_equal 0, delta[:spent_sats_delta]
      assert_equal 5, delta[:balance_sats_delta]
      assert_equal 2, delta[:live_utxo_count_delta]
      assert_equal 2, delta[:received_output_count_delta]
    end

    test "aggregates several addresses in one block" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-a",
              vout: 0,
              address: "bc1qa",
              amount_btc: "0.00000010"
            )
          ],
          cluster_inputs: [
            input(
              txid: "tx-b",
              vout: 0,
              address: "bc1qb",
              amount_btc: "0.00000004",
              block_height: 90,
              spent_block_height: HEIGHT
            )
          ]
        )

      assert_equal 2, result[:addresses_touched]
      assert_equal 1, result[:received_address_count]
      assert_equal 1, result[:spent_address_count]
      assert_equal %w[bc1qa bc1qb], result[:deltas].map { |d| d[:address] }
    end

    test "handles an output created and spent in the same block" do
      result =
        build_delta(
          cluster_inputs: [
            input(
              txid: "tx-same-block",
              vout: 0,
              address: "bc1qsameblock",
              amount_btc: "0.00000100",
              block_height: HEIGHT,
              spent_block_height: HEIGHT
            )
          ]
        )

      assert_equal 1, result[:received_output_count]
      assert_equal 1, result[:spent_output_count]
      assert_equal 100, result[:total_received_sats]
      assert_equal 100, result[:total_spent_sats]
      assert_equal 0, result[:balance_delta_sats]
      assert_empty result[:anomalies]

      delta =
        result[:deltas].first

      assert_equal 100, delta[:received_sats_delta]
      assert_equal 100, delta[:spent_sats_delta]
      assert_equal 0, delta[:balance_sats_delta]
      assert_equal 0, delta[:live_utxo_count_delta]
      assert_equal 1, delta[:received_output_count_delta]
    end

    test "deduplicates only by txid and vout" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-multi",
              vout: 0,
              address: "bc1qmulti",
              amount_btc: "0.00000001"
            ),
            utxo(
              txid: "tx-multi",
              vout: 1,
              address: "bc1qmulti",
              amount_btc: "0.00000002"
            )
          ]
        )

      assert_equal 2, result[:received_output_count]
      assert_equal 3, result[:total_received_sats]
      assert_empty result[:anomalies]
    end

    test "converts btc amounts to satoshis exactly" do
      assert_equal(
        1,
        BlockDeltaBuilder.btc_to_sats("0.00000001")
      )

      assert_equal(
        123_456_789,
        BlockDeltaBuilder.btc_to_sats("1.23456789")
      )

      assert_equal(
        5_000_000_000,
        BlockDeltaBuilder.btc_to_sats("50.0")
      )
    end

    test "reports exact duplicate outputs and counts them once" do
      duplicated =
        utxo(
          txid: "tx-duplicate",
          vout: 0,
          address: "bc1qduplicate",
          amount_btc: "0.00000001"
        )

      result =
        build_delta(
          utxo_outputs: [
            duplicated,
            duplicated.dup
          ]
        )

      assert_equal 1, result[:received_output_count]
      assert_equal 1, result[:total_received_sats]
      assert_equal [:duplicate_output], result[:anomalies].map { |a| a[:type] }
    end

    test "reports overlap between live and spent output sources" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-overlap",
              vout: 0,
              address: "bc1qoverlap",
              amount_btc: "0.00000001"
            )
          ],
          cluster_inputs: [
            input(
              txid: "tx-overlap",
              vout: 0,
              address: "bc1qoverlap",
              amount_btc: "0.00000001",
              block_height: HEIGHT,
              spent_block_height: HEIGHT + 1
            )
          ]
        )

      assert_equal 1, result[:received_output_count]

      assert_includes(
        result[:anomalies].map { |anomaly| anomaly[:type] },
        :output_overlap
      )
    end

    test "reports contradictory values for the same output key" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-contradiction",
              vout: 0,
              address: "bc1qcontradiction",
              amount_btc: "0.00000001"
            ),
            utxo(
              txid: "tx-contradiction",
              vout: 0,
              address: "bc1qcontradiction",
              amount_btc: "0.00000002"
            )
          ]
        )

      assert_includes(
        result[:anomalies].map { |anomaly| anomaly[:type] },
        :output_contradiction
      )
    end

    test "reports empty addresses and excludes them from certifiable deltas" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-empty-address",
              vout: 0,
              address: " ",
              amount_btc: "0.00000001"
            )
          ]
        )

      assert_empty result[:deltas]
      assert_equal 0, result[:total_received_sats]

      assert_equal(
        [:missing_essential_data],
        result[:anomalies].map { |anomaly| anomaly[:type] }
      )
    end

    test "returns an empty deterministic result without data" do
      result =
        build_delta

      assert_equal HEIGHT, result[:height]
      assert_equal 0, result[:addresses_touched]
      assert_equal 0, result[:received_output_count]
      assert_equal 0, result[:spent_output_count]
      assert_equal 0, result[:total_received_sats]
      assert_equal 0, result[:total_spent_sats]
      assert_equal 0, result[:balance_delta_sats]
      assert_empty result[:deltas]
      assert_empty result[:anomalies]
    end

    test "returns deterministic results independent of source row order" do
      utxos = [
        utxo(
          txid: "tx-z",
          vout: 0,
          address: "bc1qz",
          amount_btc: "0.00000003"
        ),
        utxo(
          txid: "tx-a",
          vout: 0,
          address: "bc1qa",
          amount_btc: "0.00000002"
        )
      ]

      first =
        build_delta(
          utxo_outputs: utxos
        )

      second =
        build_delta(
          utxo_outputs: utxos.reverse
        )

      assert_equal first, second
      assert_equal %w[bc1qa bc1qz], first[:deltas].map { |d| d[:address] }
    end

    test "keeps global totals coherent with address deltas" do
      result =
        build_delta(
          utxo_outputs: [
            utxo(
              txid: "tx-received",
              vout: 0,
              address: "bc1qreceived",
              amount_btc: "0.00000010"
            )
          ],
          cluster_inputs: [
            input(
              txid: "tx-spent",
              vout: 0,
              address: "bc1qspent",
              amount_btc: "0.00000004",
              block_height: 90,
              spent_block_height: HEIGHT
            ),
            input(
              txid: "tx-roundtrip",
              vout: 0,
              address: "bc1qroundtrip",
              amount_btc: "0.00000003",
              block_height: HEIGHT,
              spent_block_height: HEIGHT
            )
          ]
        )

      received_sum =
        result[:deltas].sum do |delta|
          delta[:received_sats_delta]
        end

      balance_sum =
        result[:deltas].sum do |delta|
          delta[:balance_sats_delta]
        end

      spent_sum =
        result[:deltas].sum do |delta|
          delta[:spent_sats_delta]
        end

      assert_equal received_sum, result[:total_received_sats]
      assert_equal spent_sum, result[:total_spent_sats]
      assert_equal balance_sum, result[:balance_delta_sats]
      assert_equal 13, result[:total_received_sats]
      assert_equal 7, result[:total_spent_sats]
      assert_equal 6, result[:balance_delta_sats]
      assert_empty result[:anomalies]
    end

    private

    def build_delta(
      height: HEIGHT,
      utxo_outputs: [],
      cluster_inputs: []
    )
      BlockDeltaBuilder.call(
        height: height,
        utxo_outputs: utxo_outputs,
        cluster_inputs: cluster_inputs
      )
    end

    def utxo(
      txid:,
      vout:,
      address:,
      amount_btc:,
      block_height: HEIGHT
    )
      {
        txid: txid,
        vout: vout,
        address: address,
        amount_btc: amount_btc,
        block_height: block_height
      }
    end

    def input(
      txid:,
      vout:,
      address:,
      amount_btc:,
      block_height:,
      spent_block_height:,
      spent: true
    )
      {
        txid: txid,
        vout: vout,
        address: address,
        amount_btc: amount_btc,
        block_height: block_height,
        spent_block_height: spent_block_height,
        spent: spent
      }
    end
  end
end
