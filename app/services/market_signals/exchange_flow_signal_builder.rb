# app/services/market_signals/exchange_flow_signal_builder.rb
module MarketSignals
  class ExchangeFlowSignalBuilder
    INDICATOR = "EXCHANGE_CORE_FLOW"

    def self.call
      new.call
    end

    def call
      latest = ExchangeCoreFlowDay
        .where.not(netflow_btc: nil)
        .where("events_count > 0")
        .order(day: :desc)
        .first

      return nil unless latest

      direction =
        if latest.netflow_btc.to_d.positive?
          "bearish"
        elsif latest.netflow_btc.to_d.negative?
          "bullish"
        else
          "neutral"
        end

      reason =
        case direction
        when "bearish"
          "Les flux montrent un netflow positif de #{latest.netflow_btc.to_f.round(2)} BTC vers les exchanges. Cela peut indiquer une pression vendeuse potentielle."
        when "bullish"
          "Les flux montrent un netflow négatif de #{latest.netflow_btc.to_f.round(2)} BTC. Plus de BTC sortent des exchanges qu'ils n'y entrent, ce qui peut indiquer une accumulation."
        else
          "Les flux exchanges sont équilibrés. Le signal est neutre pour Bitcoin."
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
