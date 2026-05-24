# app/services/market_predictions/fed_prediction_backtester.rb
module MarketPredictions
  class FedPredictionBacktester
    INDICATOR = "FEDFUNDS"

    def self.call
      new.call
    end

    def call
      rows = MacroIndicator
        .where(source: "fred", code: INDICATOR)
        .order(:observed_on)
        .to_a

      rows.each_cons(3) do |previous, signal_month, target_month|
        direction =
          if signal_month.value < previous.value
            "bullish"
          elsif signal_month.value > previous.value
            "bearish"
          else
            "neutral"
          end

        predicted_on = signal_month.observed_on
        target_on = target_month.observed_on

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
            source: "fred",
            indicator: INDICATOR,
            direction: direction,
            confidence: direction == "neutral" ? 50 : 55,

            predicted_on: predicted_on,
            target_on: target_on,

            btc_price_at_prediction: btc_start,
            btc_price_at_target: btc_target,

            performance_pct: performance_pct,
            result: result,

            metadata: {
              previous_fed_value: previous.value.to_f,
              signal_fed_value: signal_month.value.to_f,
              target_fed_value: target_month.value.to_f
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