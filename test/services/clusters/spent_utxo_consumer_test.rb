# frozen_string_literal: true

require "test_helper"

class Clusters::SpentUtxoConsumerTest < ActiveSupport::TestCase
  test "builds cluster inputs without repeating flusher mutations" do
    txid = "a" * 64
    spent_txid = "b" * 64

    TxOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qconsumer",
      amount_btc: BigDecimal("1.25"),
      block_height: 100,
      spent: false
    )

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qconsumer",
      amount_btc: BigDecimal("1.25"),
      block_height: 100
    )

    result = Clusters::SpentUtxoConsumer.call(
      rows: [
        {
          "txid" => txid,
          "vout" => 0,
          "spent_txid" => spent_txid,
          "spent_block_height" => 200
        }
      ]
    )

    assert result[:ok]
    assert result[:mutations_owned_by_flusher]
    assert ClusterInput.exists?(txid: txid, vout: 0, spent_txid: spent_txid)
    assert_not TxOutput.find_by!(txid: txid, vout: 0).spent?
    assert UtxoOutput.exists?(txid: txid, vout: 0)
  end
end
