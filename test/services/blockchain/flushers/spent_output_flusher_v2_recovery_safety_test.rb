# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class SpentOutputFlusherV2RecoverySafetyTest < ActiveSupport::TestCase
  class FakeRedis
    attr_reader :payloads, :lpush_calls
    attr_accessor :fail_requeue

    def initialize(payloads)
      @payloads = payloads.dup
      @lpush_calls = []
      @fail_requeue = false
    end

    def lpop(_key, count)
      @payloads.shift(count)
    end

    def lpush(_key, *values)
      @lpush_calls << values
      raise Redis::CommandError, "simulated requeue failure" if fail_requeue

      values.each { |value| @payloads.unshift(value) }
      values.size
    end
  end

  setup do
    @previous_batch_size = ENV["SPENT_OUTPUT_FLUSH_BATCH_SIZE"]
  end

  teardown do
    if @previous_batch_size.nil?
      ENV.delete("SPENT_OUTPUT_FLUSH_BATCH_SIZE")
    else
      ENV["SPENT_OUTPUT_FLUSH_BATCH_SIZE"] = @previous_batch_size
    end
  end

  test "accepts an empty recovery batch without database effects" do
    redis = FakeRedis.new([])

    result = assert_no_queries_match(/\b(?:INSERT|UPDATE|DELETE)\b/i) do
      build_flusher(redis).call
    end

    assert result[:ok]
    assert_equal 0, result[:flushed]
    assert_equal 0, result[:cluster_inserted]
    assert_equal 0, result[:utxo_deleted]
    assert_equal [], redis.lpush_calls
    assert_nothing_raised { JSON.generate(result) }
  end

  test "keeps valid and incomplete rows atomic and reports exact counters" do
    valid = spent_row(txid: "1" * 64, vout: 0, height: 700)
    incomplete = spent_row(
      txid: "2" * 64,
      vout: 1,
      height: 700,
      prevout_block_height: nil
    )
    create_utxo(valid)
    create_utxo(incomplete)

    result = assert_no_queries_match(/\btx_outputs\b/i) do
      build_flusher(FakeRedis.new(raw_payloads(valid, incomplete))).call
    end

    assert result[:ok]
    assert_equal 2, result[:flushed]
    assert_equal 1, result[:cluster_inserted]
    assert_equal 2, result[:utxo_deleted]
    assert_equal 0, result[:missing_utxo]
    assert ClusterInput.exists?(txid: valid["txid"], vout: valid["vout"])
    assert_not ClusterInput.exists?(txid: incomplete["txid"], vout: incomplete["vout"])
    assert_not UtxoOutput.exists?(txid: valid["txid"], vout: valid["vout"])
    assert_not UtxoOutput.exists?(txid: incomplete["txid"], vout: incomplete["vout"])
    assert_nothing_raised { JSON.generate(result) }
  end

  test "invalid json is restored byte for byte ahead of untouched payloads" do
    first = " {\"txid\":\"#{"3" * 64}\"} \n"
    invalid = "{not-json"
    third = JSON.generate(spent_row(txid: "4" * 64, vout: 0, height: 701))
    untouched = JSON.generate(spent_row(txid: "5" * 64, vout: 0, height: 702))
    ENV["SPENT_OUTPUT_FLUSH_BATCH_SIZE"] = "3"
    redis = FakeRedis.new([first, invalid, third, untouched])

    assert_raises(JSON::ParserError) { build_flusher(redis).call }

    assert_equal [[third, invalid, first]], redis.lpush_calls
    assert_equal [first, invalid, third, untouched], redis.payloads
    assert_equal 0, ClusterInput.where(txid: ["3" * 64, "4" * 64]).count
  end

  test "failure after copy rolls back and restores the entire raw batch" do
    rows = [
      spent_row(txid: "6" * 64, vout: 0, height: 703),
      spent_row(txid: "7" * 64, vout: 1, height: 703)
    ]
    rows.each { |row| create_utxo(row) }
    payloads = raw_payloads(*rows)
    redis = FakeRedis.new(payloads)
    flusher = build_flusher(redis)

    error = assert_raises(RuntimeError) do
      flusher.stub(:upsert_cluster_inputs_from_temp, ->(*) { raise "after copy" }) do
        flusher.call
      end
    end

    assert_equal "after copy", error.message
    assert_equal payloads, redis.payloads
    assert_equal payloads.reverse, redis.lpush_calls.fetch(0)
    rows.each do |row|
      assert_not ClusterInput.exists?(txid: row["txid"], vout: row["vout"])
      assert UtxoOutput.exists?(txid: row["txid"], vout: row["vout"])
    end
  end

  test "failure after upsert rolls cluster inputs back with utxo state" do
    row = spent_row(txid: "8" * 64, vout: 0, height: 704)
    create_utxo(row)
    payload = JSON.generate(row)
    redis = FakeRedis.new([payload])
    flusher = build_flusher(redis)

    error = assert_raises(RuntimeError) do
      flusher.stub(:delete_utxo_outputs_from_temp, ->(*) { raise "before utxo delete" }) do
        flusher.call
      end
    end

    assert_equal "before utxo delete", error.message
    assert_equal [payload], redis.payloads
    assert_not ClusterInput.exists?(txid: row["txid"], vout: row["vout"])
    assert UtxoOutput.exists?(txid: row["txid"], vout: row["vout"])
  end

  test "a simulated interruption before commit requeues without partial state" do
    row = spent_row(txid: "9" * 64, vout: 0, height: 705)
    create_utxo(row)
    payload = JSON.generate(row)
    redis = FakeRedis.new([payload])
    flusher = build_flusher(redis)

    simulated_interruption = Class.new(StandardError)

    assert_raises(simulated_interruption) do
      flusher.stub(:delete_utxo_outputs_from_temp, ->(*) { raise simulated_interruption, "stop" }) do
        flusher.call
      end
    end

    assert_equal [payload], redis.payloads
    assert_not ClusterInput.exists?(txid: row["txid"], vout: row["vout"])
    assert UtxoOutput.exists?(txid: row["txid"], vout: row["vout"])
  end

  test "requeue failure exposes both the database and redis failures" do
    row = spent_row(txid: "a" * 64, vout: 0, height: 706)
    payload = JSON.generate(row)
    redis = FakeRedis.new([payload])
    redis.fail_requeue = true
    flusher = build_flusher(redis)

    error = assert_raises(
      Blockchain::Flushers::SpentOutputFlusherV2::RequeueFailed
    ) do
      flusher.stub(:create_temp_table, ->(*) { raise "postgres failed" }) do
        flusher.call
      end
    end

    assert_instance_of RuntimeError, error.original_error
    assert_equal "postgres failed", error.original_error.message
    assert_instance_of Redis::CommandError, error.requeue_error
    assert_equal "simulated requeue failure", error.requeue_error.message
    assert_same error.original_error, error.cause
    assert_match "original=RuntimeError: postgres failed", error.message
    assert_match "requeue=Redis::CommandError: simulated requeue failure", error.message
    assert_equal [], redis.payloads
  end

  test "a requeued batch succeeds on retry without duplicate cluster inputs" do
    row = spent_row(txid: "b" * 64, vout: 0, height: 707)
    create_utxo(row)
    redis = FakeRedis.new(raw_payloads(row))
    first = build_flusher(redis)

    assert_raises(RuntimeError) do
      first.stub(:delete_utxo_outputs_from_temp, ->(*) { raise "retry me" }) do
        first.call
      end
    end

    result = build_flusher(redis).call

    assert result[:ok]
    assert_equal 1, result[:cluster_inserted]
    assert_equal 1, result[:utxo_deleted]
    assert_empty redis.payloads
    assert_equal 1, ClusterInput.where(txid: row["txid"], vout: row["vout"]).count
    assert_not UtxoOutput.exists?(txid: row["txid"], vout: row["vout"])

    second = build_flusher(FakeRedis.new(raw_payloads(row))).call
    assert second[:ok]
    assert_equal 0, second[:cluster_inserted]
    assert_equal 0, second[:utxo_deleted]
    assert_equal 1, second[:missing_utxo]
    assert_equal 1, ClusterInput.where(txid: row["txid"], vout: row["vout"]).count
  end

  test "an exception after commit never requeues the committed payload" do
    row = spent_row(txid: "1a" * 32, vout: 0, height: 708)
    create_utxo(row)
    redis = FakeRedis.new(raw_payloads(row))
    logger = Class.new do
      def info(message)
        raise "after commit" if message.start_with?("[spent_output_flusher_v2] flushed=")
      end

      def error(_message); end
    end.new
    flusher = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: redis,
      logger: logger,
      mode: :recovery
    )

    error = assert_raises(RuntimeError) { flusher.call }

    assert_equal "after commit", error.message
    assert_empty redis.payloads
    assert_empty redis.lpush_calls
    assert ClusterInput.exists?(txid: row["txid"], vout: row["vout"])
    assert_not UtxoOutput.exists?(txid: row["txid"], vout: row["vout"])
  end

  test "duplicate pairs choose a deterministic recovery source row" do
    txid = "c" * 64
    older = spent_row(
      txid: txid,
      vout: 2,
      height: 708,
      spent_txid: "d" * 64,
      prevout_address: "bc1qolder",
      prevout_amount_btc: "1.25",
      prevout_block_height: 650
    )
    newer = spent_row(
      txid: txid,
      vout: 2,
      height: 709,
      spent_txid: "e" * 64,
      prevout_address: "bc1qnewer",
      prevout_amount_btc: "2.50",
      prevout_block_height: 651
    )
    create_utxo(older)

    result = build_flusher(FakeRedis.new(raw_payloads(older, newer))).call
    input = ClusterInput.find_by!(txid: txid, vout: 2)

    assert result[:ok]
    assert_equal 2, result[:flushed]
    assert_equal 1, result[:cluster_inserted]
    assert_equal 1, result[:utxo_deleted]
    assert_equal 1, result[:missing_utxo]
    assert_equal 709, input.spent_block_height
    assert_equal "e" * 64, input.spent_txid
    assert_equal 651, input.block_height
    assert_equal "bc1qnewer", input.address
    assert_equal BigDecimal("2.50"), input.amount_btc
  end

  test "installed recovery flusher has no tx outputs cron or selector dependency" do
    source = File.read(
      Rails.root.join(
        "app/services/blockchain/flushers/spent_output_flusher_v2.rb"
      )
    )

    refute_match(/\b(?:FROM|JOIN|UPDATE|INTO|DELETE\s+FROM)\s+tx_outputs\b/i, source)
    refute_includes source, "SpentOutputFlusherSelector"
    refute_includes source, "cron_blockchain_flusher"
  end

  private

  def build_flusher(redis)
    Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: redis,
      logger: Rails.logger,
      mode: :recovery
    )
  end

  def raw_payloads(*rows)
    rows.map { |row| JSON.generate(row) }
  end

  def spent_row(
    txid:,
    vout:,
    height:,
    spent_txid: "f" * 64,
    prevout_address: "bc1qrecovery",
    prevout_amount_btc: "1.00",
    prevout_block_height: 600
  )
    {
      "txid" => txid,
      "vout" => vout,
      "spent_txid" => spent_txid,
      "spent_block_height" => height,
      "prevout_address" => prevout_address,
      "prevout_amount_btc" => prevout_amount_btc,
      "prevout_block_height" => prevout_block_height
    }
  end

  def create_utxo(row)
    UtxoOutput.create!(
      txid: row.fetch("txid"),
      vout: row.fetch("vout"),
      address: row.fetch("prevout_address"),
      amount_btc: BigDecimal(row.fetch("prevout_amount_btc")),
      block_height: row.fetch("prevout_block_height") || 1
    )
  end
end
