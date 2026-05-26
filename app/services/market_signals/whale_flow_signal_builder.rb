# frozen_string_literal: true

module MarketSignals
  class WhaleFlowSignalBuilder
    INDICATOR = "WHALE_CORE_FLOW"

    def self.call
      new.call
    end

    def call
      latest =
        WhaleCoreFlowDay
          .where("events_count > 0")
          .where.not(netflow_btc: nil)
          .order(day: :desc)
          .first

      return nil unless latest

      direction =
        if latest.netflow_btc.to_d.positive?
          "bullish"
        elsif latest.netflow_btc.to_d.negative?
          "bearish"
        else
          "neutral"
        end

      reason =
        case direction
        when "bullish"
          "Les whales reçoivent plus de BTC qu'elles n'en envoient. Cela peut indiquer une accumulation."
        when "bearish"
          "Les whales envoient plus de BTC qu'elles n'en reçoivent. Cela peut indiquer une distribution."
        else
          "Les flux whales sont équilibrés. Le signal est neutre."
        end

      MarketSignal.upsert(
        {
          source: "tansa",
          indicator: INDICATOR,
          direction: direction,
          confidence: confidence_for(direction),
          observed_on: latest.day,
          reason: reason,
          metadata: {
            inflow_btc: latest.inflow_btc.to_f,
            outflow_btc: latest.outflow_btc.to_f,
            netflow_btc: latest.netflow_btc.to_f,
            events_count: latest.events_count
          },
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: [:source, :indicator, :observed_on]
      )

      MarketSignal.find_by!(
        source: "tansa",
        indicator: INDICATOR,
        observed_on: latest.day
      )
    end

    private

    def confidence_for(direction)
      direction == "neutral" ? 50 : 60
    end
  end
end
