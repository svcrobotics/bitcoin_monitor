# frozen_string_literal: true

module Actors
  class WhaleCoreFlowDayBuilder
    def self.call(day:)
      new(day: day).call
    end

    def initialize(day:)
      @day = day.to_date
    end

    def call
      whale_cluster_ids = Actors::WhaleLikeQuery.call.pluck(:cluster_id)
      return empty_result("no_whale_like_clusters") if whale_cluster_ids.empty?

      result = ActiveRecord::Base.connection.exec_query(
        sanitized_sql(whale_cluster_ids)
      ).first

      inflow = result["inflow_btc"].to_d
      outflow = result["outflow_btc"].to_d
      inflow_count = result["inflow_count"].to_i
      outflow_count = result["outflow_count"].to_i

      row = WhaleCoreFlowDay.find_or_initialize_by(day: @day)

      row.inflow_btc = inflow
      row.outflow_btc = outflow
      row.netflow_btc = inflow - outflow
      row.events_count = inflow_count + outflow_count
      row.source = "actor_graph_whale_like"

      row.save!

      {
        ok: true,
        day: @day,
        inflow_btc: row.inflow_btc,
        outflow_btc: row.outflow_btc,
        netflow_btc: row.netflow_btc,
        events_count: row.events_count,
        inflow_count: inflow_count,
        outflow_count: outflow_count
      }
    end

    private

    def sanitized_sql(whale_cluster_ids)
      ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL,
            WITH whale_addresses AS (
              SELECT address
              FROM addresses
              WHERE cluster_id IN (?)
            ),
            day_heights AS (
              SELECT DISTINCT block_height
              FROM tx_outputs
              WHERE block_time BETWEEN ? AND ?
            ),
            inflows AS (
              SELECT
                COALESCE(SUM(txo.amount_btc), 0) AS btc,
                COUNT(*) AS count
              FROM tx_outputs txo
              INNER JOIN whale_addresses wa
                ON wa.address = txo.address
              WHERE txo.block_time BETWEEN ? AND ?
                AND txo.amount_btc IS NOT NULL
            ),
            outflows AS (
              SELECT
                COALESCE(SUM(txo.amount_btc), 0) AS btc,
                COUNT(*) AS count
              FROM tx_outputs txo
              INNER JOIN whale_addresses wa
                ON wa.address = txo.address
              INNER JOIN day_heights dh
                ON dh.block_height = txo.spent_block_height
              WHERE txo.amount_btc IS NOT NULL
            )
            SELECT
              inflows.btc AS inflow_btc,
              outflows.btc AS outflow_btc,
              inflows.count AS inflow_count,
              outflows.count AS outflow_count
            FROM inflows, outflows
          SQL
          whale_cluster_ids,
          @day.beginning_of_day,
          @day.end_of_day,
          @day.beginning_of_day,
          @day.end_of_day
        ]
      )
    end

    def empty_result(reason)
      {
        ok: true,
        day: @day,
        inflow_btc: 0,
        outflow_btc: 0,
        netflow_btc: 0,
        events_count: 0,
        reason: reason
      }
    end
  end
end