# app/services/actors/exchange_core_flow_day_builder.rb
# frozen_string_literal: true

module Actors
  class ExchangeCoreFlowDayBuilder
    def self.call(day:)
      new(day: day).call
    end

    def initialize(day:)
      @day = day.to_date
    end

    def call
      cluster_ids = exchange_cluster_ids

      inflow =
        ExchangeCoreFlowEvent
          .where(cluster_id: cluster_ids)
          .where(direction: "inflow")
          .where(event_time: day_range)
          .sum(:amount_btc)

      outflow =
        ExchangeCoreFlowEvent
          .where(cluster_id: cluster_ids)
          .where(direction: "outflow")
          .where(event_time: day_range)
          .sum(:amount_btc)

      events_count =
        ExchangeCoreFlowEvent
          .where(cluster_id: cluster_ids)
          .where(event_time: day_range)
          .count

      row = ExchangeCoreFlowDay.find_or_initialize_by(day: @day)

      row.inflow_btc = inflow
      row.outflow_btc = outflow
      row.netflow_btc = inflow - outflow
      row.events_count = events_count
      row.source =
        ActorLabels::StrictWriter::SOURCE
      row.save!

      {
        ok: true,
        day: @day,
        source: row.source,
        exchange_like_clusters: cluster_ids.size,
        inflow_btc: row.inflow_btc,
        outflow_btc: row.outflow_btc,
        netflow_btc: row.netflow_btc,
        events_count: row.events_count
      }
    end

    private

    def exchange_cluster_ids
      Actors::StrictExchangeLikeQuery
        .call
        .pluck(:cluster_id)
    end

    def day_range
      @day.beginning_of_day..@day.end_of_day
    end
  end
end