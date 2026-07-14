# frozen_string_literal: true

require "json"
require "test_helper"

class AuditBlockTest < ActiveSupport::TestCase
  test "certifies output facts from strict facts without tx_outputs" do
    height = 955_210
    block_hash = "b" * 64

    BlockBufferModel.create!(
      height: height,
      block_hash: block_hash,
      status: "processing",
      tx_count: 1
    )

    UtxoOutput.create!(
      txid: "c" * 64,
      vout: 0,
      address: "bc1qlive",
      amount_btc: BigDecimal("1.25"),
      block_height: height,
      block_hash: block_hash
    )

    ClusterInput.create!(
      block_height: height,
      txid: "d" * 64,
      vout: 1,
      address: "bc1qspent",
      amount_btc: BigDecimal("2.50"),
      spent: true,
      spent_txid: "e" * 64,
      spent_block_height: height
    )

    assert_equal 0, TxOutput.where(block_height: height).count

    with_bitcoin_cli_stub(block_hash: block_hash, block: block_payload(block_hash: block_hash)) do
      run = Layer1::AuditBlock.call(height: height)

      assert_equal "healthy", run.status
      assert_equal true, run.checks.fetch("outputs_count_matches").fetch("passed")
      assert_equal true, run.checks.fetch("outputs_value_matches").fetch("passed")
    end
  end

  test "fails when strict output facts do not match bitcoin core" do
    height = 955_211
    block_hash = "f" * 64

    BlockBufferModel.create!(
      height: height,
      block_hash: block_hash,
      status: "processing",
      tx_count: 1
    )

    UtxoOutput.create!(
      txid: "1" * 64,
      vout: 0,
      address: "bc1qshort",
      amount_btc: BigDecimal("0.10"),
      block_height: height,
      block_hash: block_hash
    )

    with_bitcoin_cli_stub(block_hash: block_hash, block: block_payload(block_hash: block_hash)) do
      run = Layer1::AuditBlock.call(height: height)

      assert_equal "failed", run.status
      assert_equal false, run.checks.fetch("outputs_count_matches").fetch("passed")
      assert_equal false, run.checks.fetch("outputs_value_matches").fetch("passed")
    end
  end

  private

  def block_payload(block_hash:)
    {
      "hash" => block_hash,
      "tx" => [
        {
          "txid" => "c" * 64,
          "vout" => [
            output_payload(0, "bc1qlive", "1.25"),
            output_payload(1, "bc1qspent", "2.50")
          ]
        }
      ]
    }
  end

  def output_payload(n, address, value)
    {
      "n" => n,
      "value" => value,
      "scriptPubKey" => { "address" => address }
    }
  end

  def with_bitcoin_cli_stub(block_hash:, block:)
    original = Layer1::AuditBlock.instance_method(:bitcoin_cli)

    Layer1::AuditBlock.define_method(:bitcoin_cli) do |command, *args|
      case command
      when "getblockhash"
        block_hash
      when "getblock"
        raise "unexpected block hash #{args.first}" unless args.first == block_hash

        JSON.generate(block)
      else
        raise "unexpected bitcoin-cli command #{command}"
      end
    end

    yield
  ensure
    Layer1::AuditBlock.define_method(:bitcoin_cli, original)
  end
end
