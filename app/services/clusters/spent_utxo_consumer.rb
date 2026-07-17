# frozen_string_literal: true

module Clusters
  class SpentUtxoConsumer
    def self.call(rows:)
      new(rows: rows).call
    end

    def initialize(rows:)
      @rows = Array(rows)
    end

    def call
      return empty_result if @rows.empty?

      Rails.logger.info("[spent_utxo_consumer] sample=#{@rows.first.inspect}")

      utxos = load_utxos
      fallback_tx_outputs = load_fallback_tx_outputs(utxos)

      cluster_rows = build_cluster_rows(
        utxos: utxos,
        fallback_tx_outputs: fallback_tx_outputs
      )

      inserted = upsert_cluster_inputs(cluster_rows)

      result = {
        ok: true,
        rows: @rows.size,
        utxos: utxos.size,
        fallback_tx_outputs: fallback_tx_outputs.size,
        cluster_rows: cluster_rows.size,
        inserted: inserted,
        mutations_owned_by_flusher: true
      }

      Rails.logger.info("[spent_utxo_consumer] #{result.inspect}")

      result
    end

    private

    def empty_result
      {
        ok: true,
        rows: 0,
        utxos: 0,
        fallback_tx_outputs: 0,
        cluster_rows: 0,
        inserted: 0,
        mutations_owned_by_flusher: true
      }
    end

    def pairs
      @pairs ||=
        @rows.map do |row|
          [
            row["txid"] || row[:txid],
            (row["vout"] || row[:vout]).to_i
          ]
        end.uniq
    end

    def load_utxos
      return {} if pairs.empty?

      UtxoOutput
        .where(pair_conditions(pairs))
        .index_by { |utxo| [utxo.txid, utxo.vout] }
    end

    def load_fallback_tx_outputs(utxos)
      missing_pairs = pairs.reject { |pair| utxos.key?(pair) }
      return {} if missing_pairs.empty?

      TxOutput
        .where(pair_conditions(missing_pairs))
        .index_by { |txo| [txo.txid, txo.vout] }
    end

    def build_cluster_rows(utxos:, fallback_tx_outputs:)
      now = Time.current
      sources = utxos.merge(fallback_tx_outputs)
      stats_by_address = address_stats(sources.values)

      @rows.filter_map do |row|
        txid = row["txid"] || row[:txid]
        vout = (row["vout"] || row[:vout]).to_i

        source = sources[[txid, vout]]

        address =
          source&.address ||
          row["prevout_address"] ||
          row[:prevout_address]

        amount_btc =
          source&.amount_btc ||
          row["prevout_amount_btc"] ||
          row[:prevout_amount_btc]

        block_height =
          source&.block_height ||
          row["prevout_block_height"] ||
          row[:prevout_block_height]

        next if address.blank?
        next if amount_btc.blank?

        stats = stats_by_address[address]

        {
          block_height: block_height.to_i,
          txid: txid,
          vout: vout,
          address: address,
          amount_btc: amount_btc,
          spent: true,
          spent_txid: row["spent_txid"] || row[:spent_txid],
          spent_block_height: (
            row["spent_block_height"] ||
            row[:spent_block_height]
          ).to_i,
          address_balance_btc: stats&.net_btc,
          address_received_btc: stats&.received_btc,
          address_sent_btc: stats&.sent_btc,
          created_at: now,
          updated_at: now
        }
      end
    end

    def upsert_cluster_inputs(cluster_rows)
      return 0 if cluster_rows.empty?

      result = ClusterInput.upsert_all(
        cluster_rows,
        unique_by: :index_cluster_inputs_on_txid_and_vout
      )

      result.rows.size
    end

    def address_stats(outputs)
      addresses = outputs.map(&:address).compact.uniq
      return {} if addresses.empty?

      AddressFlowStat.where(address: addresses).index_by(&:address)
    end

    def pair_conditions(target_pairs)
      values =
        target_pairs.map do |txid, vout|
          ActiveRecord::Base.sanitize_sql_array(
            ["(?, ?)", txid, vout.to_i]
          )
        end.join(", ")

      "(txid, vout) IN (#{values})"
    end
  end
end
