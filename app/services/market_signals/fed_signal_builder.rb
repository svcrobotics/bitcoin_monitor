# app/services/market_signals/fed_signal_builder.rb
module MarketSignals
  class FedSignalBuilder
    INDICATOR = "FEDFUNDS"

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
          "The Federal Funds Rate decreased from #{previous.value.to_f} to #{latest.value.to_f}. Lower rates may support risk assets such as Bitcoin."
        when "bearish"
          "The Federal Funds Rate increased from #{previous.value.to_f} to #{latest.value.to_f}. Higher rates may pressure risk assets such as Bitcoin."
        else
          "The Federal Funds Rate remained stable at #{latest.value.to_f}. The macro signal is neutral for Bitcoin."
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
        55
      else
        50
      end
    end
  end
end
