# app/services/market_predictions/exchange_flow_prediction_backtester.rb
module MarketPredictions
  class ExchangeFlowPredictionBacktester
    INDICATOR = "EXCHANGE_CORE_FLOW"

    def self.call
      new.call
    end

    def call
      rows = ExchangeCoreFlowDay
        .where("events_count > 0")
        .where.not(netflow_btc: nil)
        .order(:day)
        .to_a

      rows.each_cons(7) do |window|
        previous = window.first
        signal_day = window.second
        target_day = window.last

        direction =
          if signal_day.netflow_btc.to_d.positive?
            "bearish"
          elsif signal_day.netflow_btc.to_d.negative?
            "bullish"
          else
            "neutral"
          end

        predicted_on = signal_day.day
        target_on = target_day.day

        btc_start = btc_price_on(predicted_on)
        btc_target = btc_price_on(target_on)

        next if btc_start.blank? || btc_target.blank?

        performance_pct =
          (((btc_target - btc_start) / btc_start) * 100).round(2)

        result =
          case direction
          when "bullish"
            performance_pct.positive? ? "success" : "failed"
          when "bearish"
            performance_pct.negative? ? "success" : "failed"
          else
            performance_pct.abs < 3 ? "success" : "failed"
          end

        MarketPrediction.upsert(
          {
            source: "tansa",
            indicator: INDICATOR,

            direction: direction,
            confidence: direction == "neutral" ? 50 : 60,

            predicted_on: predicted_on,
            target_on: target_on,

            btc_price_at_prediction: btc_start,
            btc_price_at_target: btc_target,

            performance_pct: performance_pct,
            result: result,

            metadata: {
              inflow_btc: signal_day.inflow_btc.to_f,
              outflow_btc: signal_day.outflow_btc.to_f,
              netflow_btc: signal_day.netflow_btc.to_f,
              events_count: signal_day.events_count
            },

            created_at: Time.current,
            updated_at: Time.current
          },
          unique_by: [
            :source,
            :indicator,
            :predicted_on,
            :target_on
          ]
        )
      end
    end

    private

    def btc_price_on(date)
      BtcPriceDay
        .where("day <= ?", date)
        .order(day: :desc)
        .limit(1)
        .pick(:close_usd)
    end
  end
end
