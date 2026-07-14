# frozen_string_literal: true

require "test_helper"

class StrictOutputFactsTest < ActiveSupport::TestCase
  test "aggregates live and spent outputs without tx_outputs" do
    height = 955_220

    UtxoOutput.create!(
      txid: "1" * 64,
      vout: 0,
      address: "bc1qlive",
      amount_btc: BigDecimal("1.25"),
      block_height: height,
      block_hash: "2" * 64
    )

    ClusterInput.create!(
      block_height: height,
      txid: "3" * 64,
      vout: 1,
      address: "bc1qspent",
      amount_btc: BigDecimal("2.50"),
      spent: true,
      spent_txid: "4" * 64,
      spent_block_height: height
    )

    assert_equal 0, TxOutput.where(block_height: height).count

    facts = Layer1::StrictOutputFacts.call(height: height)

    assert_equal height, facts[:height]
    assert_equal 2, facts[:outputs_count]
    assert_equal BigDecimal("3.75"), facts[:outputs_value_btc]
    assert_equal 1, facts[:live_outputs_count]
    assert_equal BigDecimal("1.25"), facts[:live_outputs_value_btc]
    assert_equal 1, facts[:spent_outputs_count]
    assert_equal BigDecimal("2.50"), facts[:spent_outputs_value_btc]
    assert_equal 0, facts[:overlapping_state_count]
    assert_equal 0, facts[:conflicting_amounts_count]
  end

  test "detects overlapping live and spent state" do
    height = 955_221
    txid = "5" * 64

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qoverlap",
      amount_btc: BigDecimal("0.90"),
      block_height: height,
      block_hash: "6" * 64
    )

    ClusterInput.create!(
      block_height: height,
      txid: txid,
      vout: 0,
      address: "bc1qoverlap",
      amount_btc: BigDecimal("0.90"),
      spent: true,
      spent_txid: "7" * 64,
      spent_block_height: height
    )

    facts = Layer1::StrictOutputFacts.call(height: height)

    assert_equal 1, facts[:outputs_count]
    assert_equal 1, facts[:overlapping_state_count]
    assert_equal 0, facts[:conflicting_amounts_count]
  end

  test "detects conflicting amounts for the same output" do
    height = 955_222
    txid = "8" * 64

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qconflict",
      amount_btc: BigDecimal("0.90"),
      block_height: height,
      block_hash: "9" * 64
    )

    ClusterInput.create!(
      block_height: height,
      txid: txid,
      vout: 0,
      address: "bc1qconflict",
      amount_btc: BigDecimal("0.91"),
      spent: true,
      spent_txid: "a" * 64,
      spent_block_height: height
    )

    facts = Layer1::StrictOutputFacts.call(height: height)

    assert_equal 1, facts[:outputs_count]
    assert_equal 1, facts[:overlapping_state_count]
    assert_equal 1, facts[:conflicting_amounts_count]
  end
end
