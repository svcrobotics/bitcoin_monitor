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
      return { ok: true, rows: 0, inserted: 0, deleted_utxos: 0 } if @rows.empty?

      Rails.logger.info("[spent_utxo_consumer] sample=#{@rows.first.inspect}")

      utxos = load_utxos
      fallback_tx_outputs = load_fallback_tx_outputs(utxos)

      cluster_rows = build_cluster_rows(utxos, fallback_tx_outputs)
      upsert_addresses!(cluster_rows)

      inserted = 0
      if cluster_rows.any?
        result = ClusterInput.upsert_all(
          cluster_rows,
          unique_by: :index_cluster_inputs_on_txid_and_vout
        )

        inserted = result.rows.size
      end

      deleted = delete_utxos

      Rails.logger.info(
        "[spent_utxo_consumer] rows=#{@rows.size} " \
        "utxos=#{utxos.size} " \
        "fallback_tx_outputs=#{fallback_tx_outputs.size} " \
        "cluster_rows=#{cluster_rows.size} " \
        "inserted=#{inserted} " \
        "deleted=#{deleted}"
      )

      {
        ok: true,
        rows: @rows.size,
        utxos: utxos.size,
        fallback_tx_outputs: fallback_tx_outputs.size,
        inserted: inserted,
        deleted_utxos: deleted
      }
    end

    private

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
        .index_by { |u| [u.txid, u.vout] }
    end

    def load_fallback_tx_outputs(utxos)
      missing_pairs = pairs.reject { |pair| utxos.key?(pair) }
      return {} if missing_pairs.empty?

      TxOutput
        .where(pair_conditions(missing_pairs))
        .where(spent: true)
        .where.not(spent_txid: nil)
        .index_by { |txo| [txo.txid, txo.vout] }
    end

    def build_cluster_rows(utxos, fallback_tx_outputs)
      now = Time.current
      sources = utxos.merge(fallback_tx_outputs)
      stats_by_address = address_stats(sources.values)

      @rows.filter_map do |row|
        txid = row["txid"] || row[:txid]
        vout = (row["vout"] || row[:vout]).to_i

        source = sources[[txid, vout]]
        next unless source

        stats = stats_by_address[source.address]

        {
          block_height: source.block_height,
          txid: source.txid,
          vout: source.vout,
          address: source.address,
          amount_btc: source.amount_btc,
          spent: true,
          spent_txid: row["spent_txid"] || row[:spent_txid] || source.try(:spent_txid),
          spent_block_height: (
            row["spent_block_height"] ||
            row[:spent_block_height] ||
            source.try(:spent_block_height)
          ).to_i,
          address_balance_btc: stats&.net_btc,
          address_received_btc: stats&.received_btc,
          address_sent_btc: stats&.sent_btc,
          created_at: now,
          updated_at: now
        }
      end
    end

    def address_stats(outputs)
      addresses = outputs.map(&:address).compact.uniq
      return {} if addresses.empty?

      AddressFlowStat.where(address: addresses).index_by(&:address)
    end

    def upsert_addresses!(cluster_rows)
      now = Time.current

      rows =
        cluster_rows
          .filter_map { |row| row[:address].presence }
          .uniq
          .map do |address|
            {
              address: address,
              created_at: now,
              updated_at: now
            }
          end

      return if rows.empty?

      Address.upsert_all(
        rows,
        unique_by: :index_addresses_on_address
      )

      Clusters::EnsureAddressClusters.call(addresses: rows.map { |r| r[:address] })
    end

    def delete_utxos
      return 0 if pairs.empty?

      UtxoOutput.where(pair_conditions(pairs)).delete_all
    end

    def pair_conditions(target_pairs)
      target_pairs.map do |txid, vout|
        ActiveRecord::Base.sanitize_sql_array(
          ["(txid = ? AND vout = ?)", txid, vout]
        )
      end.join(" OR ")
    end
  end
end