# app/services/intelligence/context_builder.rb
# frozen_string_literal: true

module Intelligence
  class ContextBuilder
    HISTORY_DAYS = 7

    def self.exchange_flow
      today = Dashboard::ExchangeCoreNetflowToday.call
      history = exchange_flow_history

      {
        module: "exchange_flow",
        source: "actor_profile_exchange_like",

        architecture: {
          pipeline: [
            "Layer 1",
            "Clusters",
            "Actor Profiles",
            "Actor Labels",
            "Exchange Core Flow"
          ],
          note: "Les flux sont calculés uniquement depuis les acteurs exchange_like validés par Actor Profiles."
        },

        coverage: {
          requested_days: HISTORY_DAYS,
          measured_days: history.count { |row| row[:events_count].to_i.positive? },
          reliable_days: history.count { |row| row[:events_count].to_i.positive? && row[:netflow_btc].to_f.abs >= 500 },
          note: "La nouvelle architecture Exchange Core Flow est en phase de montée en charge. Les jours sans événements ou avec faible couverture doivent être interprétés avec prudence."
        },

        dominant_signal: {
          signal: today[:signal]
        },

        watch_priority: {
          watch: "Surveiller si le netflow BTC reste positif ou augmente dans la journée."
        },

        interpretation: today[:interpretation],

        today: {
          inflow_btc: today[:inflow_btc].to_f.round(2),
          outflow_btc: today[:outflow_btc].to_f.round(2),
          netflow_btc: today[:netflow_btc].to_f.round(2),
          events_count: today[:events_count].to_i,
          updated_at: today[:updated_at]
        },

        history_7d: history
      }
    end

    def self.exchange_flow_history
      from_day = Date.current - (HISTORY_DAYS - 1).days

      (from_day..Date.current).map do |day|
        range = day.beginning_of_day..day.end_of_day
        rows = ExchangeCoreFlowEvent.where(event_time: range)

        inflow_btc = rows.where(direction: "inflow").sum(:amount_btc).to_f.round(2)
        outflow_btc = rows.where(direction: "outflow").sum(:amount_btc).to_f.round(2)
        netflow_btc = (inflow_btc - outflow_btc).round(2)

        {
          day: day,
          inflow_btc: inflow_btc,
          outflow_btc: outflow_btc,
          netflow_btc: netflow_btc,
          events_count: rows.count,
          signal: signal_for(netflow_btc)
        }
      end.reverse
    end

    def self.signal_for(netflow_btc)
      if netflow_btc >= 2_000
        "selling_pressure_strong"
      elsif netflow_btc >= 500
        "selling_pressure_moderate"
      elsif netflow_btc >= 100
        "selling_pressure_weak"
      elsif netflow_btc <= -2_000
        "accumulation_strong"
      elsif netflow_btc <= -500
        "accumulation_moderate"
      elsif netflow_btc <= -100
        "accumulation_weak"
      else
        "neutral"
      end
    end
  end
end