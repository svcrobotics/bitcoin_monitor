# frozen_string_literal: true

require "test_helper"

class ReconcileStrictUtxoStateTest < ActiveSupport::TestCase
  test "deletes a utxo spent by the certified height without changing its input" do
    height = 955_300
    txid = "1" * 64

    create_utxo(txid: txid, vout: 0)
    input = create_spend(txid: txid, vout: 0, spent_block_height: height)
    input_attributes = input.attributes

    result = without_tx_outputs_queries do
      Layer1::ReconcileStrictUtxoState.call(height: height)
    end

    assert_equal true, result[:ok]
    assert_equal height, result[:height]
    assert_equal 1, result[:stale_utxos_deleted]
    assert_not UtxoOutput.exists?(txid: txid, vout: 0)
    assert_equal input_attributes, input.reload.attributes
  end

  test "preserves a utxo without a matching cluster input" do
    height = 955_301
    txid = "2" * 64

    create_utxo(txid: txid, vout: 1)

    result = without_tx_outputs_queries do
      Layer1::ReconcileStrictUtxoState.call(height: height)
    end

    assert_equal 0, result[:stale_utxos_deleted]
    assert UtxoOutput.exists?(txid: txid, vout: 1)
  end

  test "preserves a utxo spent at another height" do
    height = 955_302
    txid = "3" * 64

    create_utxo(txid: txid, vout: 2)
    input = create_spend(
      txid: txid,
      vout: 2,
      spent_block_height: height + 1
    )
    input_attributes = input.attributes

    result = without_tx_outputs_queries do
      Layer1::ReconcileStrictUtxoState.call(height: height)
    end

    assert_equal 0, result[:stale_utxos_deleted]
    assert UtxoOutput.exists?(txid: txid, vout: 2)
    assert_equal input_attributes, input.reload.attributes
  end

  test "deletes multiple pairs exactly once" do
    height = 955_303
    pairs = [
      ["4" * 64, 0],
      ["5" * 64, 3]
    ]

    pairs.each do |txid, vout|
      create_utxo(txid: txid, vout: vout)
      create_spend(
        txid: txid,
        vout: vout,
        spent_block_height: height
      )
    end

    first_result = without_tx_outputs_queries do
      Layer1::ReconcileStrictUtxoState.call(height: height)
    end
    second_result = without_tx_outputs_queries do
      Layer1::ReconcileStrictUtxoState.call(height: height)
    end

    assert_equal 2, first_result[:stale_utxos_deleted]
    assert_equal 0, second_result[:stale_utxos_deleted]
    assert_equal 0, UtxoOutput.where(txid: pairs.map(&:first)).count
    assert_equal 2, ClusterInput.where(spent_block_height: height).count
  end

  private

  def without_tx_outputs_queries(&block)
    assert_no_queries_match(/\btx_outputs\b/i, &block)
  end

  def create_utxo(txid:, vout:)
    UtxoOutput.create!(
      txid: txid,
      vout: vout,
      address: "bc1q#{txid.first(8)}",
      amount_btc: BigDecimal("1.25"),
      block_height: 955_250,
      block_hash: "a" * 64
    )
  end

  def create_spend(txid:, vout:, spent_block_height:)
    ClusterInput.create!(
      block_height: 955_250,
      txid: txid,
      vout: vout,
      address: "bc1q#{txid.first(8)}",
      amount_btc: BigDecimal("1.25"),
      spent: true,
      spent_txid: "b" * 64,
      spent_block_height: spent_block_height
    )
  end
end
