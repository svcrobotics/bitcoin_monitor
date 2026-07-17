# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class SpentOutputFlusherV2Test < ActiveSupport::TestCase
  setup do
    @previous_async_setting = ENV["TX_OUTPUTS_SPENT_ASYNC"]
    ENV.delete("TX_OUTPUTS_SPENT_ASYNC")
  end

  teardown do
    if @previous_async_setting.nil?
      ENV.delete("TX_OUTPUTS_SPENT_ASYNC")
    else
      ENV["TX_OUTPUTS_SPENT_ASYNC"] = @previous_async_setting
    end
  end

  class FakeRedis
    attr_reader :payloads

    def initialize(rows)
      @payloads = rows.map { |row| JSON.generate(row) }
    end

    def lpop(_key, count)
      @payloads.shift(count)
    end

    def lpush(_key, *values)
      @payloads.unshift(*values)
    end
  end

  test "upserts cluster inputs from bitcoin core prevout without reading or writing tx outputs" do
    utxo_txid = "a" * 64
    tx_output_txid = "b" * 64
    prevout_txid = "c" * 64
    spending_txid = "d" * 64

    TxOutput.create!(
      txid: utxo_txid,
      vout: 0,
      address: "bc1qtxoutputignored",
      amount_btc: BigDecimal("9.00"),
      block_height: 90,
      spent: false
    )

    UtxoOutput.create!(
      txid: utxo_txid,
      vout: 0,
      address: "bc1qutxowrong",
      amount_btc: BigDecimal("9.99"),
      block_height: 99
    )

    TxOutput.create!(
      txid: tx_output_txid,
      vout: 1,
      address: "bc1qtxoutputsource",
      amount_btc: BigDecimal("2.50"),
      block_height: 110,
      spent: false
    )

    AddressFlowStat.create!(
      address: "bc1qprevoutsource",
      received_btc: BigDecimal("4.00"),
      sent_btc: BigDecimal("2.75"),
      net_btc: BigDecimal("1.25")
    )

    rows = [
      {
        "txid" => utxo_txid,
        "vout" => 0,
        "spent_txid" => spending_txid,
        "spent_block_height" => 200,
        "prevout_address" => "bc1qprevoutsource",
        "prevout_amount_btc" => "1.25",
        "prevout_block_height" => 100
      },
      {
        "txid" => tx_output_txid,
        "vout" => 1,
        "spent_txid" => spending_txid,
        "spent_block_height" => 200,
        "prevout_address" => "bc1qprevoutignored2",
        "prevout_amount_btc" => "7.00",
        "prevout_block_height" => 70
      },
      {
        "txid" => prevout_txid,
        "vout" => 2,
        "spent_txid" => spending_txid,
        "spent_block_height" => 200,
        "prevout_address" => "bc1qbitcoincore",
        "prevout_amount_btc" => "3.75",
        "prevout_block_height" => 120
      }
    ]

    result = assert_no_queries_match(/\btx_outputs\b/i) do
      Blockchain::Flushers::SpentOutputFlusherV2.new(
        redis: FakeRedis.new(rows),
        logger: Rails.logger
      ).call
    end

    assert result[:ok]
    assert_equal 3, result[:flushed]
    assert_equal 0, result[:tx_updated]
    assert result[:tx_update_deferred]
    assert_nil result[:missing_tx]
    assert_equal 3, result[:cluster_inserted]
    assert_equal 1, result[:utxo_deleted]

    assert_not TxOutput.find_by!(txid: utxo_txid, vout: 0).spent?
    assert_not TxOutput.find_by!(txid: tx_output_txid, vout: 1).spent?
    assert_not UtxoOutput.exists?(txid: utxo_txid, vout: 0)

    from_utxo = ClusterInput.find_by!(txid: utxo_txid, vout: 0)
    assert_equal "bc1qprevoutsource", from_utxo.address
    assert_equal BigDecimal("1.25"), from_utxo.amount_btc
    assert_equal 100, from_utxo.block_height
    assert_equal BigDecimal("1.25"), from_utxo.address_balance_btc

    from_prevout_despite_tx_output = ClusterInput.find_by!(txid: tx_output_txid, vout: 1)
    assert_equal "bc1qprevoutignored2", from_prevout_despite_tx_output.address
    assert_equal BigDecimal("7.00"), from_prevout_despite_tx_output.amount_btc
    assert_equal 70, from_prevout_despite_tx_output.block_height

    from_prevout = ClusterInput.find_by!(txid: prevout_txid, vout: 2)
    assert_equal "bc1qbitcoincore", from_prevout.address
    assert_equal BigDecimal("3.75"), from_prevout.amount_btc
    assert_equal 120, from_prevout.block_height
  end

  test "strict results never depend on tx outputs async configuration" do
    variants = ["0", "1", "", nil]
    strict_results = []

    variants.each_with_index do |setting, index|
      if setting.nil?
        ENV.delete("TX_OUTPUTS_SPENT_ASYNC")
      else
        ENV["TX_OUTPUTS_SPENT_ASYNC"] = setting
      end

      txid = (index + 1).to_s(16) * 64
      spending_txid = (index + 10).to_s(16) * 64

      TxOutput.create!(
        txid: txid,
        vout: 0,
        address: "bc1qconfig#{index}",
        amount_btc: BigDecimal("1.00"),
        block_height: 500 + index,
        spent: false
      )

      UtxoOutput.create!(
        txid: txid,
        vout: 0,
        address: "bc1qconfig#{index}",
        amount_btc: BigDecimal("1.00"),
        block_height: 500 + index
      )

      row = spent_row(
        txid: txid,
        vout: 0,
        spent_txid: spending_txid,
        spent_block_height: 600 + index,
        prevout_address: "bc1qconfig#{index}",
        prevout_amount_btc: "1.00",
        prevout_block_height: 500 + index
      )

      result = assert_no_queries_match(/\btx_outputs\b/i) do
        Blockchain::Flushers::SpentOutputFlusherV2.new(
          redis: FakeRedis.new([row]),
          logger: Rails.logger
        ).call
      end

      strict_results << result.slice(
        :ok,
        :flushed,
        :tx_updated,
        :tx_update_deferred,
        :cluster_inserted,
        :cluster_conflicts,
        :cluster_conflicts_identical,
        :cluster_conflicts_divergent,
        :cluster_mode,
        :utxo_deleted,
        :missing_tx,
        :missing_utxo
      )

      assert_not TxOutput.find_by!(txid: txid, vout: 0).spent?
      assert ClusterInput.find_by!(txid: txid, vout: 0).spent?
      assert_not UtxoOutput.exists?(txid: txid, vout: 0)
    end

    assert_equal [strict_results.first] * variants.size, strict_results
  end

  test "installed strict flusher has no async projection switch" do
    source = File.read(
      Rails.root.join(
        "app/services/blockchain/flushers/spent_output_flusher_v2.rb"
      )
    )

    refute_match(/TX_OUTPUTS_SPENT_ASYNC/, source)
    refute_match(/TxOutputsSpentSync::Config/, source)
    refute_match(/update_tx_outputs_from_temp/, source)
    refute_includes source, "def tx_outputs_update_deferred?"
    refute_includes source, "unless tx_outputs_update_deferred?"
  end

  test "uses bitcoin core prevout for self spend in same block and deletes live utxo" do
    txid = "9" * 64
    spending_txid = "8" * 64
    height = 300

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qlocalwrong",
      amount_btc: BigDecimal("8.00"),
      block_height: height
    )

    row = {
      "txid" => txid,
      "vout" => 0,
      "spent_txid" => spending_txid,
      "spent_block_height" => height,
      "prevout_address" => "bc1qselfspend",
      "prevout_amount_btc" => "2.25",
      "prevout_block_height" => height
    }

    result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([row]),
      logger: Rails.logger
    ).call

    assert result[:ok]
    assert_equal 1, result[:cluster_inserted]
    assert_equal 1, result[:utxo_deleted]
    assert_not UtxoOutput.exists?(txid: txid, vout: 0)

    cluster_input = ClusterInput.find_by!(txid: txid, vout: 0)
    assert_equal height, cluster_input.block_height
    assert_equal "bc1qselfspend", cluster_input.address
    assert_equal BigDecimal("2.25"), cluster_input.amount_btc
    assert_equal spending_txid, cluster_input.spent_txid
    assert_equal height, cluster_input.spent_block_height
  end

  test "does not create cluster input when bitcoin core prevout height is missing" do
    txid = "7" * 64

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qlocalmustnotfallback",
      amount_btc: BigDecimal("1.00"),
      block_height: 250
    )

    row = {
      "txid" => txid,
      "vout" => 0,
      "spent_txid" => "6" * 64,
      "spent_block_height" => 350,
      "prevout_address" => "bc1qincomplete",
      "prevout_amount_btc" => "1.00",
      "prevout_block_height" => nil
    }

    result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([row]),
      logger: Rails.logger
    ).call

    assert result[:ok]
    assert_equal 0, result[:cluster_inserted]
    assert_equal 1, result[:utxo_deleted]
    assert_nil ClusterInput.find_by(txid: txid, vout: 0)
    assert_not UtxoOutput.exists?(txid: txid, vout: 0)
  end

  test "does not rewrite an unchanged cluster input on conflict" do
    ENV["TX_OUTPUTS_SPENT_ASYNC"] = "1"

    txid = "1" * 64
    spending_txid = "2" * 64

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qidempotent",
      amount_btc: BigDecimal("1.50"),
      block_height: 175
    )

    row = {
      "txid" => txid,
      "vout" => 0,
      "spent_txid" => spending_txid,
      "spent_block_height" => 250,
      "prevout_address" => "bc1qidempotent",
      "prevout_amount_btc" => "1.50",
      "prevout_block_height" => 175
    }

    first_result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([row]),
      logger: Rails.logger
    ).call

    cluster_input = ClusterInput.find_by!(txid: txid, vout: 0)
    original_updated_at = cluster_input.updated_at

    second_result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([row]),
      logger: Rails.logger
    ).call

    assert_equal 1, first_result[:cluster_inserted]
    assert_equal 0, second_result[:cluster_inserted]
    assert_equal original_updated_at, cluster_input.reload.updated_at
  end

  test "defers tx output projection while keeping cluster inputs and utxo deletion strict" do
    ENV["TX_OUTPUTS_SPENT_ASYNC"] = "1"

    txid = "e" * 64
    spending_txid = "f" * 64

    TxOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qasync",
      amount_btc: BigDecimal("1.00"),
      block_height: 150,
      spent: false
    )

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qasync",
      amount_btc: BigDecimal("1.00"),
      block_height: 150
    )

    rows = [{
      "txid" => txid,
      "vout" => 0,
      "spent_txid" => spending_txid,
      "spent_block_height" => 200,
      "prevout_address" => "bc1qasync",
      "prevout_amount_btc" => "1.00",
      "prevout_block_height" => 150
    }]

    result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new(rows),
      logger: Rails.logger
    ).call

    assert result[:ok]
    assert result[:tx_update_deferred]
    assert_equal 0, result[:tx_updated]
    assert_nil result[:missing_tx]
    assert_not TxOutput.find_by!(txid: txid, vout: 0).spent?
    assert ClusterInput.find_by!(txid: txid, vout: 0).spent?
    assert_not UtxoOutput.exists?(txid: txid, vout: 0)
  end

  test "realtime inserts new cluster input with conflict metrics" do
    txid = "3" * 64
    row = spent_row(
      txid: txid,
      vout: 0,
      spent_txid: "4" * 64,
      spent_block_height: 410,
      prevout_address: "bc1qrealtimeinsert",
      prevout_amount_btc: "1.75",
      prevout_block_height: 390
    )

    UtxoOutput.create!(
      txid: txid,
      vout: 0,
      address: "bc1qrealtimeinsert",
      amount_btc: BigDecimal("1.75"),
      block_height: 390
    )

    flusher = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([row]),
      logger: Rails.logger,
      mode: :realtime
    )

    result = nil
    flusher.stub(
      :realtime_cluster_input_conflicts,
      ->(*) { raise "conflict verification should not run" }
    ) do
      result = flusher.call
    end

    assert result[:ok]
    assert_equal :realtime, result[:cluster_mode]
    assert_equal 1, result[:cluster_inserted]
    assert_equal 0, result[:cluster_conflicts]
    assert_equal 0, result[:cluster_conflicts_identical]
    assert_equal 0, result[:cluster_conflicts_divergent]
    assert_includes result[:stage_timings], :realtime_insert_cluster_inputs
    assert_not_includes result[:stage_timings], :realtime_verify_conflicts
    assert ClusterInput.find_by!(txid: txid, vout: 0).spent?
  end

  test "realtime accepts identical cluster input conflict as idempotent" do
    txid = "4" * 64
    spent_txid = "5" * 64
    row = spent_row(
      txid: txid,
      vout: 0,
      spent_txid: spent_txid,
      spent_block_height: 420,
      prevout_address: "bc1qrealtimeidentical",
      prevout_amount_btc: "2.25",
      prevout_block_height: 400
    )

    ClusterInput.create!(
      block_height: 400,
      txid: txid,
      vout: 0,
      address: "bc1qrealtimeidentical",
      amount_btc: BigDecimal("2.25"),
      spent: true,
      spent_txid: spent_txid,
      spent_block_height: 420
    )

    result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([row]),
      logger: Rails.logger,
      mode: :realtime
    ).call

    assert result[:ok]
    assert_equal 0, result[:cluster_inserted]
    assert_equal 1, result[:cluster_conflicts]
    assert_equal 1, result[:cluster_conflicts_identical]
    assert_equal 0, result[:cluster_conflicts_divergent]
    assert_includes result[:stage_timings], :realtime_insert_cluster_inputs
    assert_includes result[:stage_timings], :realtime_verify_conflicts
  end

  test "realtime fails on divergent cluster input conflict" do
    txid = "5" * 64
    row = spent_row(
      txid: txid,
      vout: 0,
      spent_txid: "6" * 64,
      spent_block_height: 430,
      prevout_address: "bc1qincoming",
      prevout_amount_btc: "3.25",
      prevout_block_height: 410
    )

    ClusterInput.create!(
      block_height: 409,
      txid: txid,
      vout: 0,
      address: "bc1qexisting",
      amount_btc: BigDecimal("3.25"),
      spent: true,
      spent_txid: "6" * 64,
      spent_block_height: 430
    )

    error =
      assert_raises(RuntimeError) do
        Blockchain::Flushers::SpentOutputFlusherV2.new(
          redis: FakeRedis.new([row]),
          logger: Rails.logger,
          mode: :realtime
        ).call
      end

    assert_match "divergent cluster_inputs in realtime spent flusher", error.message
    assert_match "samples=", error.message
    assert_match "bc1qexisting", error.message
    assert_match "bc1qincoming", error.message

    existing = ClusterInput.find_by!(txid: txid, vout: 0)
    assert_equal 409, existing.block_height
    assert_equal "bc1qexisting", existing.address
  end

  test "realtime accepts mixed new and identical cluster inputs" do
    existing_txid = "8" * 64
    new_txid = "9" * 64
    spent_txid = "a" * 64

    existing_row = spent_row(
      txid: existing_txid,
      vout: 0,
      spent_txid: spent_txid,
      spent_block_height: 450,
      prevout_address: "bc1qmixedidentical",
      prevout_amount_btc: "5.25",
      prevout_block_height: 430
    )

    new_row = spent_row(
      txid: new_txid,
      vout: 1,
      spent_txid: spent_txid,
      spent_block_height: 450,
      prevout_address: "bc1qmixednew",
      prevout_amount_btc: "6.25",
      prevout_block_height: 431
    )

    ClusterInput.create!(
      block_height: 430,
      txid: existing_txid,
      vout: 0,
      address: "bc1qmixedidentical",
      amount_btc: BigDecimal("5.25"),
      spent: true,
      spent_txid: spent_txid,
      spent_block_height: 450
    )

    result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([existing_row, new_row]),
      logger: Rails.logger,
      mode: :realtime
    ).call

    assert result[:ok]
    assert_equal 1, result[:cluster_inserted]
    assert_equal 1, result[:cluster_conflicts]
    assert_equal 1, result[:cluster_conflicts_identical]
    assert_equal 0, result[:cluster_conflicts_divergent]
    assert ClusterInput.find_by!(txid: new_txid, vout: 1).spent?
    assert_includes result[:stage_timings], :realtime_verify_conflicts
  end

  test "realtime rolls back mixed new and divergent cluster inputs atomically" do
    existing_txid = "a" * 64
    new_txid = "b" * 64
    spent_txid = "c" * 64

    divergent_row = spent_row(
      txid: existing_txid,
      vout: 0,
      spent_txid: spent_txid,
      spent_block_height: 460,
      prevout_address: "bc1qincomingdivergent",
      prevout_amount_btc: "7.25",
      prevout_block_height: 440
    )

    new_row = spent_row(
      txid: new_txid,
      vout: 1,
      spent_txid: spent_txid,
      spent_block_height: 460,
      prevout_address: "bc1qrolledback",
      prevout_amount_btc: "8.25",
      prevout_block_height: 441
    )

    ClusterInput.create!(
      block_height: 439,
      txid: existing_txid,
      vout: 0,
      address: "bc1qexistingdivergent",
      amount_btc: BigDecimal("7.25"),
      spent: true,
      spent_txid: spent_txid,
      spent_block_height: 460
    )

    assert_no_difference -> { ClusterInput.count } do
      error =
        assert_raises(RuntimeError) do
          Blockchain::Flushers::SpentOutputFlusherV2.new(
            redis: FakeRedis.new([divergent_row, new_row]),
            logger: Rails.logger,
            mode: :realtime
          ).call
        end

      assert_match "divergent cluster_inputs in realtime spent flusher", error.message
      assert_match "bc1qincomingdivergent", error.message
    end

    assert_nil ClusterInput.find_by(txid: new_txid, vout: 1)

    existing = ClusterInput.find_by!(txid: existing_txid, vout: 0)
    assert_equal 439, existing.block_height
    assert_equal "bc1qexistingdivergent", existing.address
  end

  test "recovery continues to update divergent cluster input conflict" do
    txid = "6" * 64
    spent_txid = "7" * 64
    row = spent_row(
      txid: txid,
      vout: 0,
      spent_txid: spent_txid,
      spent_block_height: 440,
      prevout_address: "bc1qrecoverycorrected",
      prevout_amount_btc: "4.25",
      prevout_block_height: 420
    )

    ClusterInput.create!(
      block_height: 419,
      txid: txid,
      vout: 0,
      address: "bc1qrecoverywrong",
      amount_btc: BigDecimal("4.00"),
      spent: true,
      spent_txid: spent_txid,
      spent_block_height: 440
    )

    result = Blockchain::Flushers::SpentOutputFlusherV2.new(
      redis: FakeRedis.new([row]),
      logger: Rails.logger,
      mode: :recovery
    ).call

    assert result[:ok]
    assert_equal :recovery, result[:cluster_mode]
    assert_equal 1, result[:cluster_inserted]
    assert_equal 0, result[:cluster_conflicts_divergent]

    corrected = ClusterInput.find_by!(txid: txid, vout: 0)
    assert_equal 420, corrected.block_height
    assert_equal "bc1qrecoverycorrected", corrected.address
    assert_equal BigDecimal("4.25"), corrected.amount_btc
    assert_not_includes result[:stage_timings], :realtime_insert_cluster_inputs
    assert_not_includes result[:stage_timings], :realtime_verify_conflicts
  end

  private

  def spent_row(
    txid:,
    vout:,
    spent_txid:,
    spent_block_height:,
    prevout_address:,
    prevout_amount_btc:,
    prevout_block_height:
  )
    {
      "txid" => txid,
      "vout" => vout,
      "spent_txid" => spent_txid,
      "spent_block_height" => spent_block_height,
      "prevout_address" => prevout_address,
      "prevout_amount_btc" => prevout_amount_btc,
      "prevout_block_height" => prevout_block_height
    }
  end
end
