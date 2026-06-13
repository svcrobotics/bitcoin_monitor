# frozen_string_literal: true

module Actors
  class ExchangeCoreFlowsController < ApplicationController
    EVENT_SOURCE = "actor_profile_exchange_like"

    def index
      @range = params[:range].presence_in(%w[7d 30d]) || "7d"
      history_days = @range == "30d" ? 30 : 7

      @today_flow = Dashboard::ExchangeCoreNetflowToday.call
      @flows = history_from_events(days: history_days)

      indexed_flows = @flows.index_by { |row| row[:day] }

      @inflow_daily = fill_daily_series(
        indexed_flows.transform_values { |r| r[:inflow_btc].to_d.round(2) },
        days: history_days
      )

      @outflow_daily = fill_daily_series(
        indexed_flows.transform_values { |r| r[:outflow_btc].to_d.round(2) },
        days: history_days
      )

      @netflow_daily = fill_daily_series(
        indexed_flows.transform_values { |r| r[:netflow_btc].to_d.round(2) },
        days: history_days
      )

      @latest_flow = @flows.first

      @summary = {
        today: @today_flow,
        latest_day: @latest_flow
      }

      @flow_days_count = @flows.size

      @engine_status = engine_status
      @recent_realtime_events = []
    end

    def live
      @today_flow = Dashboard::ExchangeCoreNetflowToday.call

      render partial: "actors/exchange_core_flows/live",
             locals: { today: @today_flow }
    end

    private

    def history_from_events(days:)
      start_day = (days - 1).days.ago.to_date
      end_day = Date.current

      rows =
        ExchangeCoreFlowEvent
          .where(source: EVENT_SOURCE)
          .where(event_time: start_day.beginning_of_day..Time.current)
          .group("DATE(event_time)")
          .pluck(
            Arel.sql("DATE(event_time)"),
            Arel.sql("SUM(CASE WHEN direction = 'inflow' THEN amount_btc ELSE 0 END)"),
            Arel.sql("SUM(CASE WHEN direction = 'outflow' THEN amount_btc ELSE 0 END)"),
            Arel.sql("COUNT(*)")
          )
          .to_h do |day, inflow, outflow, events_count|
            inflow = inflow.to_d
            outflow = outflow.to_d
            netflow = inflow - outflow

            [
              day.to_date,
              {
                day: day.to_date,
                inflow_btc: inflow,
                outflow_btc: outflow,
                netflow_btc: netflow,
                events_count: events_count.to_i,
                source: EVENT_SOURCE,
                signal: signal_for(netflow)
              }
            ]
          end

      (start_day..end_day)
        .map { |day| rows[day] || empty_day(day) }
        .sort_by { |row| row[:day] }
        .reverse
    end

    def engine_status
      Rails.cache.fetch("exchange_core_flows:engine_status", expires_in: 5.minutes) do
        exchange_actor_count =
          ActorLabel.where(source: "actor_profile", label: "exchange_like").count

        last_event_at =
          ExchangeCoreFlowEvent.where(source: EVENT_SOURCE).maximum(:event_time)

        last_block_height =
          ExchangeCoreFlowEvent.where(source: EVENT_SOURCE).maximum(:block_height)

        {
          source: EVENT_SOURCE,
          label_source: "actor_profile",
          exchange_like_labels: exchange_actor_count,
          core_addresses: nil,
          last_event_at: last_event_at,
          last_block_height: last_block_height,
          generated_at: Time.current
        }
      end
    end

    def empty_day(day)
      {
        day: day,
        inflow_btc: 0.to_d,
        outflow_btc: 0.to_d,
        netflow_btc: 0.to_d,
        events_count: 0,
        source: "missing",
        signal: "neutral"
      }
    end

    def signal_for(netflow)
      netflow = netflow.to_d

      if netflow >= 2_000
        "selling_pressure_strong"
      elsif netflow >= 500
        "selling_pressure_moderate"
      elsif netflow >= 100
        "selling_pressure_weak"
      elsif netflow <= -2_000
        "accumulation_strong"
      elsif netflow <= -500
        "accumulation_moderate"
      elsif netflow <= -100
        "accumulation_weak"
      else
        "neutral"
      end
    end

    def fill_daily_series(data, days:)
      start_day = (days - 1).days.ago.to_date

      (start_day..Date.current).each_with_object({}) do |day, h|
        h[day] = data[day] || 0
      end
    end
  end
end