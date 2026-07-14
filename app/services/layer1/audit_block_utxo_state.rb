# frozen_string_literal: true

require "bigdecimal"
require "set"

module Layer1
  class AuditBlockUtxoState
    class SnapshotUnavailable < StandardError; end
    class BlockHashChanged < StandardError; end

    def self.call(height:)
      new(height: height).call
    end

    def initialize(height:)
      @height = height.to_i
      @checks = {}
      @issues = []
    end

    def call
      connection = ActiveRecord::Base.connection
      ensure_outer_transaction_available!(connection)

      rpc = BitcoinRpc.new
      node_block_hash = rpc.getblockhash(@height).to_s
      node_block = rpc.getblock(node_block_hash, 2)

      with_consistent_snapshot(connection) do
        audit_snapshot(
          node_block: node_block,
          node_block_hash: node_block_hash
        )
      end
    end

    private

    def audit_snapshot(node_block:, node_block_hash:)
      block_buffer = BlockBufferModel.find_by(height: @height)
      raise "BlockBufferModel missing for height #{@height}" unless block_buffer

      unless block_buffer.block_hash == node_block_hash
        raise(
          BlockHashChanged,
          "BlockBuffer block_hash changed for height #{@height}: " \
          "bitcoin_core=#{node_block_hash} postgresql=#{block_buffer.block_hash}"
        )
      end

      payload_block_hash = node_block["hash"].presence || node_block_hash

      check!(
        "block_hash_matches_bitcoin_core",
        payload_block_hash == block_buffer.block_hash,
        expected: block_buffer.block_hash,
        actual: payload_block_hash
      )

      created_outputs = node_created_outputs(node_block)
      spent_created_outputs = spent_created_outputs_scope
      expected_live_outputs = expected_live_outputs(
        created_outputs,
        spent_created_outputs
      )
      actual_live_utxos = UtxoOutput.where(block_height: @height)

      expected_live_count = expected_live_outputs.size
      actual_live_count = actual_live_utxos.count

      expected_live_value = expected_live_outputs.sum(BigDecimal("0")) do |output|
        output[:amount_btc]
      end
      actual_live_value = BigDecimal(actual_live_utxos.sum(:amount_btc).to_s)

      check!(
        "utxo_live_outputs_count_matches",
        actual_live_count == expected_live_count,
        expected: expected_live_count,
        actual: actual_live_count
      )

      check!(
        "utxo_live_outputs_value_matches",
        actual_live_value == expected_live_value,
        expected: "#{expected_live_value.to_s("F")} BTC",
        actual: "#{actual_live_value.to_s("F")} BTC"
      )

      pair_check = check_live_pairs(expected_live_outputs, actual_live_utxos)

      check!(
        "utxo_live_pairs_match",
        pair_check[:missing].empty? && pair_check[:unexpected].empty?,
        expected: {
          live_pairs: pair_check[:expected_count],
          missing_sample: pair_check[:missing].first(10)
        },
        actual: {
          utxo_pairs: pair_check[:actual_count],
          unexpected_sample: pair_check[:unexpected].first(10)
        }
      )

      spent_local_inputs = ClusterInput.where(spent_block_height: @height)
      spent_inputs_not_marked = spent_local_inputs.where.not(spent: true).count
      spent_rows_still_in_utxo = spent_inputs_still_in_utxo_count

      check!(
        "spent_cluster_inputs_are_marked_spent",
        spent_inputs_not_marked.zero?,
        expected: 0,
        actual: spent_inputs_not_marked
      )

      check!(
        "spent_cluster_inputs_removed_from_utxo",
        spent_rows_still_in_utxo.zero?,
        expected: 0,
        actual: spent_rows_still_in_utxo
      )

      orphan_utxos_count =
        orphan_utxos_created_at_height_count(
          created_outputs,
          actual_live_utxos
        )
      spent_utxos_count = spent_utxos_created_at_height_count

      check!(
        "utxos_have_matching_bitcoin_core_outputs",
        orphan_utxos_count.zero?,
        expected: 0,
        actual: orphan_utxos_count
      )

      check!(
        "utxos_are_not_recorded_spent_in_cluster_inputs",
        spent_utxos_count.zero?,
        expected: 0,
        actual: spent_utxos_count
      )

      {
        ok: @issues.empty?,
        height: @height,
        block_hash: block_buffer.block_hash,
        created_outputs_count: created_outputs.size,
        expected_live_outputs_count: expected_live_count,
        actual_live_utxos_count: actual_live_count,
        expected_live_value_btc: expected_live_value.to_s("F"),
        actual_live_value_btc: actual_live_value.to_s("F"),
        spent_cluster_inputs_count: spent_local_inputs.count,
        spent_inputs_not_marked: spent_inputs_not_marked,
        spent_rows_still_in_utxo: spent_rows_still_in_utxo,
        orphan_utxos_count: orphan_utxos_count,
        spent_utxos_count: spent_utxos_count,
        checks: @checks,
        issues: @issues
      }
    end

    def ensure_outer_transaction_available!(connection)
      return unless connection.transaction_open?

      raise(
        SnapshotUnavailable,
        "AuditBlockUtxoState requires an outer REPEATABLE READ READ ONLY " \
        "transaction, but the PostgreSQL connection already has an open transaction"
      )
    end

    def with_consistent_snapshot(connection)
      ensure_outer_transaction_available!(connection)

      ActiveRecord::Base.uncached do
        connection.transaction(
          isolation: :repeatable_read,
          joinable: false
        ) do
          connection.execute("SET TRANSACTION READ ONLY")
          yield
        end
      end
    end

    def node_created_outputs(node_block)
      node_block.fetch("tx").flat_map do |tx|
        tx.fetch("vout").map do |vout|
          {
            txid: tx.fetch("txid"),
            vout: vout.fetch("n"),
            amount_btc: BigDecimal(vout.fetch("value").to_s)
          }
        end
      end
    end

    def spent_created_outputs_scope
      ClusterInput
        .where(block_height: @height, spent: true)
        .where("spent_block_height <= ?", @height)
    end

    def expected_live_outputs(created_outputs, spent_created_outputs)
      spent_pairs =
        spent_created_outputs
          .pluck(:txid, :vout)
          .map { |txid, vout| pair_key(txid, vout) }
          .to_set

      created_outputs.reject do |output|
        spent_pairs.include?(pair_key(output[:txid], output[:vout]))
      end
    end

    def check_live_pairs(expected_live_outputs, actual_live_utxos)
      expected_pairs =
        expected_live_outputs
          .map { |output| pair_key(output[:txid], output[:vout]) }
          .to_set

      actual_pairs =
        actual_live_utxos
          .pluck(:txid, :vout)
          .map { |txid, vout| pair_key(txid, vout) }
          .to_set

      {
        expected_count: expected_pairs.size,
        actual_count: actual_pairs.size,
        missing: (expected_pairs - actual_pairs).to_a,
        unexpected: (actual_pairs - expected_pairs).to_a
      }
    end

    def spent_inputs_still_in_utxo_count
      sql = ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COUNT(*)
          FROM cluster_inputs ci
          INNER JOIN utxo_outputs u
            ON u.txid = ci.txid
           AND u.vout = ci.vout
          WHERE ci.spent_block_height = ?
        SQL
        @height
      ])

      ActiveRecord::Base.connection.select_value(sql).to_i
    end

    def orphan_utxos_created_at_height_count(created_outputs, actual_live_utxos)
      node_pairs =
        created_outputs
          .map { |output| pair_key(output[:txid], output[:vout]) }
          .to_set

      actual_live_utxos
        .pluck(:txid, :vout)
        .count { |txid, vout| !node_pairs.include?(pair_key(txid, vout)) }
    end

    def spent_utxos_created_at_height_count
      sql = ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COUNT(*)
          FROM utxo_outputs u
          INNER JOIN cluster_inputs ci
            ON ci.txid = u.txid
           AND ci.vout = u.vout
          WHERE u.block_height = ?
            AND ci.spent = TRUE
            AND ci.spent_block_height <= ?
        SQL
        @height,
        @height
      ])

      ActiveRecord::Base.connection.select_value(sql).to_i
    end

    def pair_key(txid, vout)
      "#{txid}:#{vout}"
    end

    def check!(name, passed, expected:, actual:)
      @checks[name] = {
        passed: passed,
        expected: expected,
        actual: actual
      }

      return if passed

      @issues << {
        check: name,
        expected: expected,
        actual: actual
      }
    end
  end
end
