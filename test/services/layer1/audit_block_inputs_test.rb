# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class AuditBlockInputsTest < ActiveSupport::TestCase
  test "audits addressable strict inputs from verbosity 3 prevouts" do
    height = 955_230
    block_hash = "a" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_cluster_input(
      height: height,
      txid: "b" * 64,
      vout: 1,
      address: "bc1qstrictinput",
      amount_btc: BigDecimal("2.50")
    )

    block = {
      "tx" => [
        { "txid" => "c" * 64, "vin" => [{ "coinbase" => "03a0bb0d" }] },
        transaction_with_prevout(
          spending_txid: "d" * 64,
          previous_txid: "b" * 64,
          previous_vout: 1,
          value: "2.50",
          address: "bc1qstrictinput"
        ),
        transaction_with_prevout(
          spending_txid: "e" * 64,
          previous_txid: "f" * 64,
          previous_vout: 0,
          value: "0.75",
          address: nil
        )
      ]
    }

    result = audit(height: height, block_hash: block_hash, block: block)

    assert_equal true, result[:ok]
    assert_equal 2, result[:all_node_inputs_count]
    assert_equal 1, result[:unclusterable_node_inputs_count]
    assert_equal 1, result[:node_inputs_count]
    assert_equal 1, result[:db_inputs_count]
    assert_equal "2.5", result[:node_inputs_value_btc]
    assert_equal "2.5", result[:db_inputs_value_btc]
    assert_empty result[:issues]
    assert_empty result[:warnings]
  end

  test "reports a missing verbosity 3 prevout as an audit issue" do
    height = 955_231
    block_hash = "1" * 64

    create_block_buffer(height: height, block_hash: block_hash)

    block = {
      "tx" => [
        {
          "txid" => "2" * 64,
          "vin" => [{ "txid" => "3" * 64, "vout" => 4 }]
        }
      ]
    }

    result = audit(height: height, block_hash: block_hash, block: block)

    assert_equal false, result[:ok]
    assert_equal "bitcoin_core_prevout_missing", result[:issues].first.fetch(:check)
    assert_equal "2" * 64, result[:issues].first.fetch(:txid)
    assert_equal "3" * 64, result[:issues].first.fetch(:prev_txid)
    assert_equal 4, result[:issues].first.fetch(:prev_vout)
  end

  test "fails count and value checks when strict inputs diverge" do
    height = 955_232
    block_hash = "4" * 64

    create_block_buffer(height: height, block_hash: block_hash)

    block = {
      "tx" => [
        transaction_with_prevout(
          spending_txid: "5" * 64,
          previous_txid: "6" * 64,
          previous_vout: 0,
          value: "1.25",
          address: "bc1qmissingstrictinput"
        )
      ]
    }

    result = audit(height: height, block_hash: block_hash, block: block)

    assert_equal false, result[:ok]
    assert_equal false, result[:checks].fetch("cluster_inputs_count_matches").fetch(:passed)
    assert_equal false, result[:checks].fetch("cluster_inputs_value_matches").fetch(:passed)
    assert_equal 2, result[:issues].size
  end

  test "keeps missing database addresses as a warning" do
    height = 955_233
    block_hash = "7" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_cluster_input(
      height: height,
      txid: "8" * 64,
      vout: 2,
      address: nil,
      amount_btc: BigDecimal("0.50")
    )

    block = {
      "tx" => [
        transaction_with_prevout(
          spending_txid: "9" * 64,
          previous_txid: "8" * 64,
          previous_vout: 2,
          value: "0.50",
          address: "bc1qnodeaddress"
        )
      ]
    }

    result = audit(height: height, block_hash: block_hash, block: block)

    assert_equal true, result[:ok]
    assert_equal 1, result[:missing_address_count]
    assert_equal 0.0, result[:address_coverage_percent]
    assert_equal 1, result[:warnings].size
    assert_equal "cluster_inputs_have_addresses", result[:warnings].first.fetch(:check)
  end

  private

  def audit(height:, block_hash:, block:)
    rpc = Minitest::Mock.new
    rpc.expect(:getblock, block, [block_hash, 3])

    result = nil

    BitcoinRpc.stub(:new, rpc) do
      result = assert_no_queries_match(/tx_outputs/i) do
        Layer1::AuditBlockInputs.call(height: height)
      end
    end

    rpc.verify
    result
  end

  def create_block_buffer(height:, block_hash:)
    BlockBufferModel.create!(
      height: height,
      block_hash: block_hash,
      status: "processing"
    )
  end

  def create_cluster_input(height:, txid:, vout:, address:, amount_btc:)
    ClusterInput.create!(
      block_height: height - 1,
      txid: txid,
      vout: vout,
      address: address,
      amount_btc: amount_btc,
      spent: true,
      spent_txid: "0" * 64,
      spent_block_height: height
    )
  end

  def transaction_with_prevout(
    spending_txid:,
    previous_txid:,
    previous_vout:,
    value:,
    address:
  )
    script = address ? { "address" => address } : { "type" => "nulldata" }

    {
      "txid" => spending_txid,
      "vin" => [
        {
          "txid" => previous_txid,
          "vout" => previous_vout,
          "prevout" => {
            "generated" => false,
            "height" => 900_000,
            "value" => value,
            "scriptPubKey" => script
          }
        }
      ]
    }
  end
end
