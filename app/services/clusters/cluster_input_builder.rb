# frozen_string_literal: true

module Clusters
  class ClusterInputBuilder
    BATCH_SIZE = ENV.fetch("CLUSTER_INPUT_BATCH_SIZE", "50").to_i

    def self.call(from_height:, to_height:, after_id: nil)
      new(from_height:, to_height:, after_id: after_id).call
    end

    def initialize(from_height:, to_height:, after_id: nil)
      @from_height = from_height.to_i
      @to_height = to_height.to_i
      @after_id = after_id.to_i if after_id.present?
    end

    def call
      tx_outputs = load_tx_outputs
      rows = build_rows(tx_outputs)
      upsert_addresses!(rows)

      return empty_result if rows.empty?

      result = ClusterInput.upsert_all(
        rows,
        unique_by: :index_cluster_inputs_on_txid_and_vout
      )

      {
        ok: true,
        inserted: result.rows.size,
        rows: rows.size,
        from_height: @from_height,
        to_height: @to_height,
        after_id: @after_id,
        last_tx_output_id: tx_outputs.last&.id,
        has_more: tx_outputs.size >= BATCH_SIZE
      }
    end

    private

    def load_tx_outputs
      scope =
        TxOutput
          .where(block_height: @from_height..@to_height)
          .order(:id)
          .limit(BATCH_SIZE)

      scope = scope.where("id > ?", @after_id) if @after_id.present?

      scope.to_a
    end

    def build_rows(tx_outputs)
      now = Time.current
      stats_by_address = address_stats(tx_outputs)

      tx_outputs.map do |txo|
        stats = stats_by_address[txo.address]

        {
          block_height: txo.block_height,
          txid: txo.txid,
          vout: txo.vout,
          address: txo.address,
          amount_btc: txo.amount_btc,
          spent: txo.spent,
          spent_txid: txo.spent_txid,
          spent_block_height: txo.spent_block_height,
          address_balance_btc: stats&.net_btc,
          address_received_btc: stats&.received_btc,
          address_sent_btc: stats&.sent_btc,
          created_at: now,
          updated_at: now
        }
      end
    end

    def address_stats(tx_outputs)
      addresses = tx_outputs.map(&:address).compact.uniq
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

    def empty_result
      {
        ok: true,
        inserted: 0,
        rows: 0,
        from_height: @from_height,
        to_height: @to_height,
        after_id: @after_id,
        last_tx_output_id: nil,
        has_more: false
      }
    end
  end
end