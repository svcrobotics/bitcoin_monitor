# frozen_string_literal: true

module Actors
  class ExchangeCoreFlowsController < ApplicationController
    EVENT_SOURCE = "actor_profile_exchange_like"

    def index
      @range = params[:range].presence_in(%w[7d 30d]) || "7d"
      history_days = @range == "30d" ? 30 : 7

      load_exchange_like_scope!

      @today_flow = today_flow_from_actor_profile_events

      start_day = history_days.days.ago.to_date
      end_day = Date.current

      event_flows = event_flows_by_day(start_day)
      day_flows = day_flows_by_day(start_day, end_day)

      @flows =
        (start_day..end_day)
          .map do |day|
            event_flows[day] || day_flows[day] || empty_day(day)
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

      @flow_days_count = @flows.size

      @recent_realtime_events =
        ExchangeCoreFlowEvent
          .where(source: EVENT_SOURCE)
          .where(cluster_id: @exchange_cluster_ids)
          .order(event_time: :desc)
          .limit(20)

      @engine_status = {
        source: EVENT_SOURCE,
        label_source: "actor_profile",
        exchange_like_labels: @exchange_actor_count,
        core_addresses: @core_address_count,
        generated_at: Time.current
      }
    end

    def live
      load_exchange_like_scope!

      @today_flow = today_flow_from_actor_profile_events

      render partial: "actors/exchange_core_flows/live",
             locals: {
               today: @today_flow
             }
    end

    private

    def load_exchange_like_scope!
      @exchange_labels =
        ActorLabel
          .where(source: "actor_profile", label: "exchange_like")
          .includes(:actor_profile)
          .order(confidence: :desc)

      @exchange_cluster_ids = @exchange_labels.pluck(:cluster_id)

      @exchange_actor_count = @exchange_cluster_ids.size

      @core_address_count =
        if @exchange_cluster_ids.empty?
          0
        else
          Address.where(cluster_id: @exchange_cluster_ids).count
        end
    end

    def event_flows_by_day(start_day)
      return {} if @exchange_cluster_ids.empty?

      ExchangeCoreFlowEvent
        .where(source: EVENT_SOURCE)
        .where(cluster_id: @exchange_cluster_ids)
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
              source: EVENT_SOURCE
            }
          ]
        end
        .to_h
    end

    def day_flows_by_day(start_day, end_day)
      ExchangeCoreFlowDay
        .where(source: EVENT_SOURCE)
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
              source: EVENT_SOURCE
            }
          ]
        end
        .to_h
    end

    def empty_day(day)
      {
        day: day,
        inflow_btc: 0.to_d,
        outflow_btc: 0.to_d,
        netflow_btc: 0.to_d,
        events_count: 0,
        source: "missing"
      }
    end

    def today_flow_from_actor_profile_events
      return empty_today_flow if @exchange_cluster_ids.empty?

      range = Time.current.beginning_of_day..Time.current

      inflow =
        ExchangeCoreFlowEvent
          .where(source: EVENT_SOURCE)
          .where(cluster_id: @exchange_cluster_ids)
          .where(direction: "inflow")
          .where(event_time: range)
          .sum(:amount_btc)

      outflow =
        ExchangeCoreFlowEvent
          .where(source: EVENT_SOURCE)
          .where(cluster_id: @exchange_cluster_ids)
          .where(direction: "outflow")
          .where(event_time: range)
          .sum(:amount_btc)

      events_count =
        ExchangeCoreFlowEvent
          .where(source: EVENT_SOURCE)
          .where(cluster_id: @exchange_cluster_ids)
          .where(event_time: range)
          .count

      netflow = inflow.to_d - outflow.to_d

      {
        inflow_btc: inflow,
        outflow_btc: outflow,
        netflow_btc: netflow,
        events_count: events_count,
        updated_at: Time.current,
        source: EVENT_SOURCE,
        interpretation: interpretation_for(netflow)
      }
    end

    def empty_today_flow
      {
        inflow_btc: 0.to_d,
        outflow_btc: 0.to_d,
        netflow_btc: 0.to_d,
        events_count: 0,
        updated_at: Time.current,
        source: EVENT_SOURCE,
        interpretation: "Aucun acteur exchange_like validé par Actor Profiles n’a encore produit de flux aujourd’hui."
      }
    end

    def interpretation_for(netflow)
      netflow = netflow.to_d

      if netflow >= 2_000
        "Forte pression vendeuse potentielle : les dépôts nets vers exchanges dominent."
      elsif netflow >= 500
        "Pression vendeuse potentielle : les dépôts nets vers exchanges sont supérieurs aux retraits."
      elsif netflow <= -2_000
        "Forte accumulation potentielle : les retraits nets depuis exchanges dominent."
      elsif netflow <= -500
        "Accumulation potentielle : les retraits nets depuis exchanges sont supérieurs aux dépôts."
      else
        "Flux neutres : aucun déséquilibre majeur détecté."
      end
    end

    def fill_daily_series(data, days:)
      start_day = days.days.ago.to_date

      (start_day..Date.current).each_with_object({}) do |day, h|
        h[day] = data[day] || 0
      end
    end
  end
end