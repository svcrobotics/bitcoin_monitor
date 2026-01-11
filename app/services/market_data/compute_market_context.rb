# app/services/market_data/compute_market_context.rb
module MarketData
  class ComputeMarketContext
    class Error < StandardError; end

    NEUTRAL_BAND = 0.03 # ±3%
    NEAR_ATH     = -0.15
    MID_ZONE     = -0.50

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def call
      ensure_enough_data!

      price_now = latest_close!
      ma200     = ma200!
      ath       = ath_over_available_data! # ATH sur période dispo (365j aujourd'hui)
      drawdown  = pct_change(price_now, ath) # négatif si sous ATH
      amp_30d   = amplitude_30d!(price_now)

      bias  = market_bias(price_now, ma200)
      cycle = cycle_zone(drawdown)
      risk  = risk_level(bias, cycle, amp_30d)

      reasons = build_reasons(price_now, ma200, drawdown, amp_30d)

      snapshot = MarketSnapshot.create!(
        computed_at: Time.current,
        price_now_usd: price_now,
        ma200_usd: ma200,
        price_vs_ma200_pct: pct_change(price_now, ma200),
        ath_usd: ath,
        drawdown_pct: drawdown,
        amplitude_30d_pct: amp_30d,
        market_bias: bias,
        cycle_zone: cycle,
        risk_level: risk,
        reasons: reasons,
        status: "ok"
      )

      @logger.info("[MarketData::ComputeMarketContext] ok bias=#{bias} cycle=#{cycle} risk=#{risk}")
      snapshot
    rescue => e
      @logger.error("[MarketData::ComputeMarketContext] error: #{e.class} #{e.message}")
      MarketSnapshot.create!(
        computed_at: Time.current,
        market_bias: "neutral",
        cycle_zone: "mid",
        risk_level: "medium",
        reasons: ["Erreur de calcul: #{e.class}"],
        status: "error",
        error_message: e.message
      )
    end

    private

    def ensure_enough_data!
      if BtcPriceDay.count < 200
        raise Error, "Not enough btc_price_days (need >= 200, have #{BtcPriceDay.count})"
      end
    end

    def latest_close!
      BtcPriceDay.order(day: :desc).limit(1).pick(:close_usd).to_d
    end

    def ma200!
      closes = BtcPriceDay.order(day: :desc).limit(200).pluck(:close_usd).map(&:to_d)
      closes.sum / closes.size
    end

    def ath_over_available_data!
      BtcPriceDay.maximum(:close_usd).to_d
    end

    def amplitude_30d!(price_now)
      from_day = BtcPriceDay.order(day: :desc).limit(30).pluck(:day).min
      scope    = BtcPriceDay.where("day >= ?", from_day)

      max_30 = scope.maximum(:close_usd).to_d
      min_30 = scope.minimum(:close_usd).to_d

      (max_30 - min_30) / price_now
    end

    def pct_change(a, b)
      return 0.to_d if b.to_d.zero?
      (a.to_d - b.to_d) / b.to_d
    end

    def market_bias(price_now, ma200)
      delta = pct_change(price_now, ma200)
      return "bull" if delta > NEUTRAL_BAND
      return "bear" if delta < -NEUTRAL_BAND
      "neutral"
    end

    def cycle_zone(drawdown)
      # drawdown est négatif (ex: -0.32)
      return "near_ath" if drawdown >= NEAR_ATH
      return "mid" if drawdown >= MID_ZONE
      "accumulation"
    end

    def volatility_label(amp_30d)
      if amp_30d < 0.15
        "calme"
      elsif amp_30d <= 0.30
        "modérée"
      else
        "élevée"
      end
    end

    def risk_level(bias, cycle, amp_30d)
      # Base risk
      base =
        if bias == "bull" && cycle == "near_ath"
          "high"
        elsif bias == "bear" && cycle == "accumulation"
          "low"
        else
          "medium"
        end

      # Volatilité: si élevée → +1 cran
      if amp_30d > 0.30
        return "high" unless base == "high"
      end

      base
    end

    def build_reasons(price_now, ma200, drawdown, amp_30d)
      pct_ma  = (pct_change(price_now, ma200) * 100).round(1)
      dd_pct  = (drawdown * 100).round(1)
      amp_pct = (amp_30d * 100).round(1)

      [
        format("Prix à %+0.1f%% vs MA200", pct_ma),
        format("BTC à %0.1f%% du plus haut (sur période dispo)", dd_pct),
        format("Volatilité 30j : %0.1f%% (%s)", amp_pct, volatility_label(amp_30d))
      ]
    end
  end
end
