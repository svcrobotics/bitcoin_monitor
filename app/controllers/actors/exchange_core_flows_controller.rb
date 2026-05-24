# frozen_string_literal: true

module Actors
  class ExchangeCoreFlowsController < ApplicationController
    def index
      @range = params[:range].presence_in(%w[7d 30d]) || "7d"
      history_days = @range == "30d" ? 30 : 7

      @today_flow = Dashboard::ExchangeCoreNetflowToday.call

      start_day = history_days.days.ago.to_date
      end_day = Date.current

      event_flows =
        ExchangeCoreFlowEvent
          .where(event_time: start_day.beginning_of_day..Time.current)
          .group("DATE(event_time)")
          .pluck(
            Arel.sql("DATE(event_time)"),
            Arel.sql("SUM(CASE WHEN direction = 'inflow' THEN amount_btc ELSE 0 END)"),
            Arel.sql("SUM(CASE WHEN direction = 'outflow' THEN amount_btc ELSE 0 END)"),
            Arel.sql("COUNT(*)")
          )
          .map do |day, inflow, outflow, events_count|
            inflow = inflow.to_d
            outflow = outflow.to_d

            [
              day.to_date,
              {
                day: day.to_date,
                inflow_btc: inflow,
                outflow_btc: outflow,
                netflow_btc: inflow - outflow,
                events_count: events_count.to_i,
                source: "events"
              }
            ]
          end
          .to_h

      day_flows =
        ExchangeCoreFlowDay
          .where(day: start_day..end_day)
          .map do |row|
            [
              row.day,
              {
                day: row.day,
                inflow_btc: row.inflow_btc.to_d,
                outflow_btc: row.outflow_btc.to_d,
                netflow_btc: row.netflow_btc.to_d,
                events_count: row.events_count.to_i,
                source: "daily"
              }
            ]
          end
          .to_h

      @flows =
        (start_day..end_day)
          .map do |day|
            event_flows[day] || day_flows[day] || {
              day: day,
              inflow_btc: 0.to_d,
              outflow_btc: 0.to_d,
              netflow_btc: 0.to_d,
              events_count: 0,
              source: "missing"
            }
          end
          .sort_by { |row| row[:day] }
          .reverse

      indexed_flows = @flows.index_by { |row| row[:day] }

      @inflow_daily =
        fill_daily_series(
          indexed_flows.transform_values { |r| r[:inflow_btc].to_d.round(2) },
          days: history_days
        )

      @outflow_daily =
        fill_daily_series(
          indexed_flows.transform_values { |r| r[:outflow_btc].to_d.round(2) },
          days: history_days
        )

      @netflow_daily =
        fill_daily_series(
          indexed_flows.transform_values { |r| r[:netflow_btc].to_d.round(2) },
          days: history_days
        )

      @latest_flow = @flows.first

      @summary = {
        today: @today_flow,
        latest_day: @latest_flow
      }

      @exchange_actor_count =
        Actors::ExchangeLikeQuery.call.count

      @core_address_count =
        Actors::ExchangeFlowCoreAddressesQuery.call.count

      @flow_days_count = @flows.size

      @recent_realtime_events =
        ExchangeCoreFlowEvent
          .order(event_time: :desc)
          .limit(20)

      @engine_status = {
        source: "actor_graph_realtime",
        label_source: "actor_metric",
        min_confidence: 100,
        min_tx_count: 100,
        generated_at: Time.current
      }
    end

    def live
      @today_flow = Dashboard::ExchangeCoreNetflowToday.call

      render partial: "actors/exchange_core_flows/live",
             locals: {
               today: @today_flow
             }
    end

    private

    def fill_daily_series(data, days:)
      start_day = days.days.ago.to_date

      (start_day..Date.current).each_with_object({}) do |day, h|
        h[day] = data[day] || 0
      end
    end
  end
end