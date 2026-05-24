# app/services/market_signals/dxy_signal_builder.rb
module MarketSignals
  class DxySignalBuilder
    INDICATOR = "DTWEXBGS"

    def self.call
      new.call
    end

    def call
      rows = MacroIndicator
        .where(source: "fred", code: INDICATOR)
        .order(:observed_on)
        .last(2)

      return nil if rows.size < 2

      previous, latest = rows

      direction =
        if latest.value < previous.value
          "bullish"
        elsif latest.value > previous.value
          "bearish"
        else
          "neutral"
        end

      reason =
        case direction
        when "bullish"
          "The U.S. Dollar Index decreased from #{previous.value.to_f.round(2)} to #{latest.value.to_f.round(2)}. A weaker dollar may support Bitcoin and other risk assets."
        when "bearish"
          "The U.S. Dollar Index increased from #{previous.value.to_f.round(2)} to #{latest.value.to_f.round(2)}. A stronger dollar may pressure Bitcoin and other risk assets."
        else
          "The U.S. Dollar Index remained stable around #{latest.value.to_f.round(2)}. The macro signal is neutral for Bitcoin."
        end

      MarketSignal.upsert(
        {
          source: "fred",
          indicator: INDICATOR,
          direction: direction,
          confidence: confidence_for(direction),
          observed_on: latest.observed_on,

          reason: reason,

          metadata: {
            previous_value: previous.value.to_f,
            latest_value: latest.value.to_f,
            previous_observed_on: previous.observed_on,
            latest_observed_on: latest.observed_on
          },

          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: [:source, :indicator, :observed_on]
      )

      MarketSignal.find_by!(
        source: "fred",
        indicator: INDICATOR,
        observed_on: latest.observed_on
      )
    end

    private

    def confidence_for(direction)
      case direction
      when "bullish", "bearish"
        60
      else
        50
      end
    end
  end
end
