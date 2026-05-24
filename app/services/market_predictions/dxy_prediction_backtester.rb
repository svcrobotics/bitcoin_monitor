# app/services/market_predictions/dxy_prediction_backtester.rb
module MarketPredictions
  class DxyPredictionBacktester
    INDICATOR = "DTWEXBGS"

    def self.call
      new.call
    end

    def call
      rows = MacroIndicator
        .where(source: "fred", code: INDICATOR)
        .order(:observed_on)
        .to_a

      rows.each_cons(30) do |window|
        previous = window.first
        signal_day = window.second
        target_day = window.last

        direction =
          if signal_day.value < previous.value
            "bullish"
          elsif signal_day.value > previous.value
            "bearish"
          else
            "neutral"
          end

        predicted_on = signal_day.observed_on
        target_on = target_day.observed_on

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
            confidence: direction == "neutral" ? 50 : 60,

            predicted_on: predicted_on,
            target_on: target_on,

            btc_price_at_prediction: btc_start,
            btc_price_at_target: btc_target,

            performance_pct: performance_pct,
            result: result,

            metadata: {
              previous_dxy_value: previous.value.to_f,
              signal_dxy_value: signal_day.value.to_f,
              target_dxy_value: target_day.value.to_f
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
