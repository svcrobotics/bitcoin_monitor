# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class AuditBlockUtxoStateTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  HEIGHT_RANGE = (955_200..955_209)

  setup do
    cleanup_test_rows
  end

  teardown do
    cleanup_test_rows
  end

  test "certifies live and spent outputs without tx_outputs" do
    height = 955_200
    block_hash = "1" * 64
    live_txid = "2" * 64
    spent_txid = "3" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_utxo_output(
      txid: live_txid,
      vout: 0,
      amount_btc: "1.25",
      block_height: height,
      block_hash: block_hash
    )
    create_cluster_input(
      txid: spent_txid,
      vout: 1,
      amount_btc: "2.50",
      block_height: height,
      spent_block_height: height
    )

    assert_equal 0, TxOutput.where(block_height: height).count

    result, sql =
      capture_sql do
        with_bitcoin_rpc_block(
          block_payload(
            block_hash: block_hash,
            outputs: [
              output_payload(live_txid, 0, "1.25"),
              output_payload(spent_txid, 1, "2.50")
            ]
          )
        ) do
          Layer1::AuditBlockUtxoState.call(height: height)
        end
      end

    assert_consistent_snapshot_sql(sql)
    refute sql.any? { |statement| statement.match?(/tx_outputs/i) }
    assert result[:ok], result[:issues].inspect
    assert_equal 2, result[:created_outputs_count]
    assert_equal 1, result[:expected_live_outputs_count]
    assert_equal 1, result[:actual_live_utxos_count]
    assert_equal "1.25", result[:expected_live_value_btc]
    assert_equal "1.25", result[:actual_live_value_btc]
    assert_equal 1, result[:spent_cluster_inputs_count]
    assert_equal 0, result[:spent_rows_still_in_utxo]
    assert_equal 0, result[:orphan_utxos_count]
    assert_equal 0, result[:spent_utxos_count]
    assert_equal true, result[:checks].fetch("spent_cluster_inputs_removed_from_utxo").fetch(:passed)
    assert_equal true, result[:checks].fetch("utxos_are_not_recorded_spent_in_cluster_inputs").fetch(:passed)
  end

  test "rejects a live utxo whose origin is not in the audited bitcoin core block" do
    height = 955_201
    block_hash = "4" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_utxo_output(
      txid: "5" * 64,
      vout: 0,
      amount_btc: "0.75",
      block_height: height,
      block_hash: block_hash
    )

    assert_equal 0, TxOutput.where(block_height: height).count

    result =
      with_bitcoin_rpc_block(
        block_payload(block_hash: block_hash, outputs: [])
      ) do
        Layer1::AuditBlockUtxoState.call(height: height)
      end

    assert_not result[:ok]
    assert_includes result[:checks].keys, "utxos_have_matching_bitcoin_core_outputs"
  end

  test "accepts output created and spent in the same block as non live final state" do
    height = 955_202
    block_hash = "6" * 64
    txid = "7" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_cluster_input(
      txid: txid,
      vout: 0,
      amount_btc: "3.10",
      block_height: height,
      spent_block_height: height
    )

    assert_equal 0, TxOutput.where(block_height: height).count
    assert_equal 0, UtxoOutput.where(block_height: height).count

    result =
      with_bitcoin_rpc_block(
        block_payload(
          block_hash: block_hash,
          outputs: [output_payload(txid, 0, "3.10")]
        )
      ) do
        Layer1::AuditBlockUtxoState.call(height: height)
      end

    assert result[:ok], result[:issues].inspect
    assert_equal 1, result[:created_outputs_count]
    assert_equal 0, result[:expected_live_outputs_count]
    assert_equal 0, result[:actual_live_utxos_count]
    assert_equal 1, result[:spent_cluster_inputs_count]
    assert_equal 0, result[:spent_rows_still_in_utxo]
    assert_equal 0, result[:spent_utxos_count]
    assert_equal true, result[:checks].fetch("spent_cluster_inputs_removed_from_utxo").fetch(:passed)
    assert_equal true, result[:checks].fetch("utxos_are_not_recorded_spent_in_cluster_inputs").fetch(:passed)
  end

  test "rejects spent output that remains live after block certification" do
    height = 955_203
    block_hash = "8" * 64
    txid = "9" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_utxo_output(
      txid: txid,
      vout: 0,
      amount_btc: "0.40",
      block_height: height,
      block_hash: block_hash
    )
    create_cluster_input(
      txid: txid,
      vout: 0,
      amount_btc: "0.40",
      block_height: height,
      spent_block_height: height
    )

    result =
      with_bitcoin_rpc_block(
        block_payload(
          block_hash: block_hash,
          outputs: [output_payload(txid, 0, "0.40")]
        )
      ) do
        Layer1::AuditBlockUtxoState.call(height: height)
      end

    assert_not result[:ok]
    assert_equal 1, result[:spent_rows_still_in_utxo]
    assert_equal 1, result[:spent_utxos_count]
    assert_equal false, result[:checks].fetch("spent_cluster_inputs_removed_from_utxo").fetch(:passed)
    assert_equal false, result[:checks].fetch("utxos_are_not_recorded_spent_in_cluster_inputs").fetch(:passed)
  end

  test "rejects an earlier output consumed by the block but still live" do
    height = 955_204
    block_hash = "b" * 64
    txid = "c" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_utxo_output(
      txid: txid,
      vout: 0,
      amount_btc: "0.60",
      block_height: height - 1,
      block_hash: "d" * 64
    )
    create_cluster_input(
      txid: txid,
      vout: 0,
      amount_btc: "0.60",
      block_height: height - 1,
      spent_block_height: height
    )

    result =
      with_bitcoin_rpc_block(
        block_payload(block_hash: block_hash, outputs: [])
      ) do
        Layer1::AuditBlockUtxoState.call(height: height)
      end

    assert_not result[:ok]
    assert_equal 1, result[:spent_rows_still_in_utxo]
    assert_equal 0, result[:spent_utxos_count]
    assert_equal false, result[:checks].fetch("spent_cluster_inputs_removed_from_utxo").fetch(:passed)
    assert_equal true, result[:checks].fetch("utxos_are_not_recorded_spent_in_cluster_inputs").fetch(:passed)
  end

  test "keeps an output live when its spend is after the audited height" do
    height = 955_205
    block_hash = "e" * 64
    txid = "f" * 64

    create_block_buffer(height: height, block_hash: block_hash)
    create_utxo_output(
      txid: txid,
      vout: 0,
      amount_btc: "0.70",
      block_height: height,
      block_hash: block_hash
    )
    create_cluster_input(
      txid: txid,
      vout: 0,
      amount_btc: "0.70",
      block_height: height,
      spent_block_height: height + 1
    )

    result =
      with_bitcoin_rpc_block(
        block_payload(
          block_hash: block_hash,
          outputs: [output_payload(txid, 0, "0.70")]
        )
      ) do
        Layer1::AuditBlockUtxoState.call(height: height)
      end

    assert result[:ok], result[:issues].inspect
    assert_equal 1, result[:expected_live_outputs_count]
    assert_equal 1, result[:actual_live_utxos_count]
    assert_equal 0, result[:spent_rows_still_in_utxo]
    assert_equal 0, result[:spent_utxos_count]
  end

  test "rejects a block hash changed between bitcoin core and the snapshot" do
    height = 955_206
    database_hash = "1" * 64
    node_hash = "2" * 64

    create_block_buffer(height: height, block_hash: database_hash)

    error =
      assert_raises(Layer1::AuditBlockUtxoState::BlockHashChanged) do
        with_bitcoin_rpc_block(
          block_payload(block_hash: node_hash, outputs: [])
        ) do
          Layer1::AuditBlockUtxoState.call(height: height)
        end
      end

    assert_includes error.message, "height #{height}"
    assert_includes error.message, "bitcoin_core=#{node_hash}"
    assert_includes error.message, "postgresql=#{database_hash}"
  end

  test "refuses an encompassing postgres transaction" do
    height = 955_207
    block_hash = "3" * 64

    error = nil

    ActiveRecord::Base.transaction do
      error =
        assert_raises(Layer1::AuditBlockUtxoState::SnapshotUnavailable) do
          with_bitcoin_rpc_block(
            block_payload(block_hash: block_hash, outputs: [])
          ) do
            Layer1::AuditBlockUtxoState.call(height: height)
          end
        end
    end

    assert_includes error.message, "already has an open transaction"
  end

  test "uses one snapshot when another connection commits strict rows" do
    height = 955_208
    block_hash = "4" * 64
    txid = "5" * 64

    create_block_buffer(height: height, block_hash: block_hash)

    original_find_by = BlockBufferModel.method(:find_by)
    inserted = false

    finder = lambda do |*args, **kwargs|
      block = original_find_by.call(*args, **kwargs)

      unless inserted
        inserted = true

        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ActiveRecord::Base.transaction do
              create_utxo_output(
                txid: txid,
                vout: 0,
                amount_btc: "0.80",
                block_height: height,
                block_hash: block_hash
              )
              create_cluster_input(
                txid: txid,
                vout: 0,
                amount_btc: "0.80",
                block_height: height,
                spent_block_height: height
              )
            end
          end
        end.value
      end

      block
    end

    result =
      BlockBufferModel.stub(:find_by, finder) do
        with_bitcoin_rpc_block(
          block_payload(block_hash: block_hash, outputs: [])
        ) do
          Layer1::AuditBlockUtxoState.call(height: height)
        end
      end

    assert result[:ok], result[:issues].inspect
    assert_equal 0, result[:actual_live_utxos_count]
    assert_equal 0, result[:spent_cluster_inputs_count]
    assert_equal 0, result[:spent_rows_still_in_utxo]
    assert_equal 0, result[:spent_utxos_count]
    assert_equal 1, UtxoOutput.where(block_height: height).count
    assert_equal 1, ClusterInput.where(spent_block_height: height).count
  end

  private

  def cleanup_test_rows
    ClusterInput
      .where(
        "block_height BETWEEN ? AND ? OR " \
        "spent_block_height BETWEEN ? AND ?",
        HEIGHT_RANGE.begin - 1,
        HEIGHT_RANGE.end + 1,
        HEIGHT_RANGE.begin - 1,
        HEIGHT_RANGE.end + 1
      )
      .delete_all

    UtxoOutput
      .where(block_height: (HEIGHT_RANGE.begin - 1)..(HEIGHT_RANGE.end + 1))
      .delete_all

    TxOutput
      .where(block_height: (HEIGHT_RANGE.begin - 1)..(HEIGHT_RANGE.end + 1))
      .delete_all

    BlockBufferModel.where(height: HEIGHT_RANGE).delete_all
  end

  def capture_sql
    statements = []

    callback = lambda do |_name, _start, _finish, _id, payload|
      statements << payload.fetch(:sql)
    end

    result =
      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        yield
      end

    [result, statements]
  end

  def assert_consistent_snapshot_sql(statements)
    begin_index =
      statements.index do |statement|
        statement.match?(/BEGIN ISOLATION LEVEL REPEATABLE READ/i)
      end

    read_only_index =
      statements.index do |statement|
        statement.match?(/SET TRANSACTION READ ONLY/i)
      end

    strict_read_indexes =
      statements.each_index.select do |index|
        statements[index].match?(/\b(block_buffers|utxo_outputs|cluster_inputs)\b/i)
      end

    refute_nil begin_index
    refute_nil read_only_index
    assert_operator begin_index, :<, read_only_index
    assert_not_empty strict_read_indexes
    assert strict_read_indexes.all? { |index| index > read_only_index }
  end

  def create_block_buffer(height:, block_hash:)
    BlockBufferModel.create!(
      height: height,
      block_hash: block_hash,
      status: "processing",
      tx_count: 1
    )
  end

  def create_utxo_output(txid:, vout:, amount_btc:, block_height:, block_hash:)
    UtxoOutput.create!(
      txid: txid,
      vout: vout,
      address: "bc1q#{txid.first(8)}",
      amount_btc: BigDecimal(amount_btc),
      block_height: block_height,
      block_hash: block_hash
    )
  end

  def create_cluster_input(txid:, vout:, amount_btc:, block_height:, spent_block_height:)
    ClusterInput.create!(
      block_height: block_height,
      txid: txid,
      vout: vout,
      address: "bc1q#{txid.first(8)}",
      amount_btc: BigDecimal(amount_btc),
      spent: true,
      spent_txid: "a" * 64,
      spent_block_height: spent_block_height
    )
  end

  def block_payload(block_hash:, outputs:)
    {
      "hash" => block_hash,
      "tx" => outputs.map do |output|
        {
          "txid" => output.fetch(:txid),
          "vout" => [
            {
              "n" => output.fetch(:vout),
              "value" => output.fetch(:value),
              "scriptPubKey" => {
                "address" => "bc1q#{output.fetch(:txid).first(8)}"
              }
            }
          ]
        }
      end
    }
  end

  def output_payload(txid, vout, value)
    {
      txid: txid,
      vout: vout,
      value: value
    }
  end

  def with_bitcoin_rpc_block(block)
    fake_rpc = Object.new
    fake_rpc.define_singleton_method(:getblockhash) do |_height|
      block.fetch("hash")
    end
    fake_rpc.define_singleton_method(:getblock) do |block_hash, verbosity|
      raise "unexpected block hash #{block_hash}" unless block_hash == block.fetch("hash")
      raise "unexpected verbosity #{verbosity}" unless verbosity == 2

      block
    end

    original = BitcoinRpc.method(:new)
    BitcoinRpc.define_singleton_method(:new) { fake_rpc }

    yield
  ensure
    BitcoinRpc.define_singleton_method(:new) do |*args, **kwargs, &block_arg|
      original.call(*args, **kwargs, &block_arg)
    end
  end
end
