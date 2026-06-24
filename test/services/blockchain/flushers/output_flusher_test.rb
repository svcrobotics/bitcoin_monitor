# frozen_string_literal: true

require "test_helper"

class OutputFlusherTest < ActiveSupport::TestCase
  class FakeRedis
    def initialize(rows)
      @payloads = rows.map { |row| JSON.generate(row) }
    end

    def lpop(_key, count)
      @payloads.shift(count)
    end
  end

  test "writes utxo outputs without inserting tx outputs" do
    txid = "a" * 64

    result =
      Blockchain::Flushers::OutputFlusher.new(
        redis: FakeRedis.new([output_row(txid: txid)]),
        logger: Rails.logger
      ).call

    assert result[:ok]
    assert_equal 1, result[:flushed]
    assert_equal 0, result[:tx_inserted]
    assert_equal 1, result[:utxo_inserted]
    assert_equal 0, result[:tx_skipped]
    assert_equal 0, result[:utxo_skipped]
    assert result[:tx_outputs_deferred]
    assert_not_includes result[:stage_timings].keys, :insert_tx_outputs

    utxo = UtxoOutput.find_by!(txid: txid, vout: 0)
    assert_equal "bc1qoutput", utxo.address
    assert_equal BigDecimal("1.25"), utxo.amount_btc
    assert_equal 956_010, utxo.block_height

    assert_equal 0, TxOutput.where(txid: txid, vout: 0).count
  end

  test "keeps utxo output insertion idempotent while tx outputs stay deferred" do
    txid = "b" * 64
    row = output_row(txid: txid)

    first =
      Blockchain::Flushers::OutputFlusher.new(
        redis: FakeRedis.new([row]),
        logger: Rails.logger
      ).call

    second =
      Blockchain::Flushers::OutputFlusher.new(
        redis: FakeRedis.new([row]),
        logger: Rails.logger
      ).call

    assert_equal 1, first[:utxo_inserted]
    assert_equal 0, second[:utxo_inserted]
    assert first[:tx_outputs_deferred]
    assert second[:tx_outputs_deferred]
    assert_equal 1, UtxoOutput.where(txid: txid, vout: 0).count
    assert_equal 0, TxOutput.where(txid: txid, vout: 0).count
  end

  private

  def output_row(txid:)
    {
      "txid" => txid,
      "vout" => 0,
      "address" => "bc1qoutput",
      "amount_btc" => "1.25",
      "block_height" => 956_010,
      "block_hash" => "f" * 64,
      "block_time" => "2026-06-24 12:00:00",
      "spent_txid" => nil,
      "spent_block_height" => nil,
      "created_at" => "2026-06-24 12:00:00",
      "updated_at" => "2026-06-24 12:00:00"
    }
  end
end
