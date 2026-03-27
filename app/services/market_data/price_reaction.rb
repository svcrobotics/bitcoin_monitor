# frozen_string_literal: true

# app/services/market_data/price_reaction.rb
#
# Price reaction = confirmation par le prix
# Compare close(D) -> close(D+1) sur btc_price_days
#
# Usage:
#   MarketData::PriceReaction.call(day: Date.today - 1)
#   #=> { dir:, pct:, label:, cls:, from:, to: }
#
module MarketData
  class PriceReaction
    DEFAULT_THRESHOLD_PCT = 1.0

    def self.call(day:, threshold_pct: DEFAULT_THRESHOLD_PCT)
      new(day: day, threshold_pct: threshold_pct).call
    end

    def initialize(day:, threshold_pct:)
      @day = coerce_date(day)
      @threshold_pct = threshold_pct.to_f.abs
    end

    def call
      return na("missing day") unless @day

      d0 = @day
      d1 = @day + 1

      c0 = close_for(d0)
      c1 = close_for(d1)

      return na("missing close") if c0.nil? || c1.nil? || c0.to_f <= 0.0

      pct = ((c1.to_f / c0.to_f) - 1.0) * 100.0

      dir =
        if pct <= -@threshold_pct
          :down
        elsif pct >= @threshold_pct
          :up
        else
          :flat
        end

      label = format_label(dir, pct)

      {
        dir: dir,
        pct: pct,
        label: label,
        cls: css_class(dir),
        from: c0.to_f,
        to: c1.to_f
      }
    end

    private

    def close_for(day)
      # btc_price_days: day (date) + close_usd
      BtcPriceDay.where(day: day).pick(:close_usd)
    end

    def format_label(dir, pct)
      sign = pct >= 0 ? "+" : ""
      case dir
      when :up   then "⬆️ #{sign}#{pct.round(2)}%"
      when :down then "⬇️ #{sign}#{pct.round(2)}%"
      when :flat then "➖ #{sign}#{pct.round(2)}%"
      else            "—"
      end
    end

    def css_class(dir)
      # classes utiles pour ton tableau (facultatif mais pratique)
      case dir
      when :up   then "text-emerald-300"
      when :down then "text-rose-300"
      when :flat then "text-gray-300"
      else            "text-gray-500"
      end
    end

    def na(_reason)
      { dir: :na, pct: nil, label: "—", cls: "text-gray-500", from: nil, to: nil }
    end

    def coerce_date(x)
      return x if x.is_a?(Date)
      return x.to_date if x.respond_to?(:to_date)
      Date.parse(x.to_s)
    rescue
      nil
    end
  end
end
