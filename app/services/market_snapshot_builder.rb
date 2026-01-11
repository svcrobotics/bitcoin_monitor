# frozen_string_literal: true

class MarketSnapshotBuilder
  class << self
    def call = new.call
  end

  def call
    computed_at = Time.current

    closes = BtcPriceDay.order(:day).pluck(:close_usd).map(&:to_f)
    raise "No BTC price data" if closes.size < 210

    price_now = closes.last
    ma200     = closes.last(200).sum / 200.0
    ath       = closes.max

    # % humains (ex: -12.8 => -12.8%)
    price_vs_ma200_pct = ((price_now - ma200) / ma200.to_f * 100.0).round(2)
    drawdown_pct       = ((price_now - ath)  / ath.to_f  * 100.0).round(2) # négatif si sous ATH

    last30    = closes.last(30)
    amp30_pct = (((last30.max - last30.min) / last30.min.to_f) * 100.0).round(2)

    # 🔁 valeurs "bull/bear/neutral" (plus simple pour ta vue actuelle)
    market_bias =
      if price_vs_ma200_pct >= 2.0
        "bull"
      elsif price_vs_ma200_pct <= -2.0
        "bear"
      else
        "neutral"
      end

    # 🔁 cycle : near_ath / mid / accumulation (colle à ta vue dashboard)
    cycle_zone =
      if drawdown_pct >= -10
        "near_ath"
      elsif drawdown_pct <= -35
        "accumulation"
      else
        "mid"
      end

    # ⚠️ risk : low/medium/high (colle à ta vue)
    risk_level =
      if amp30_pct >= 20
        "high"
      elsif amp30_pct >= 12
        "medium"
      else
        "low"
      end

    reasons = []
    reasons << (price_now >= ma200 ? "Prix au-dessus de la MA200" : "Prix sous la MA200")
    reasons << "vs MA200: #{price_vs_ma200_pct}%"
    reasons << "Drawdown ATH: #{drawdown_pct}%"
    reasons << "Volatilité 30j: #{amp30_pct}%"

    MarketSnapshot.create!(
      computed_at: computed_at,
      price_now_usd: price_now,
      ma200_usd: ma200,
      price_vs_ma200_pct: price_vs_ma200_pct,
      ath_usd: ath,
      drawdown_pct: drawdown_pct,
      amplitude_30d_pct: amp30_pct,
      market_bias: market_bias,
      cycle_zone: cycle_zone,
      risk_level: risk_level,
      reasons: reasons,
      status: "ok",
      error_message: nil
    )
  rescue => e
    MarketSnapshot.create!(
      computed_at: Time.current,
      market_bias: "neutral",
      cycle_zone: "unknown",
      risk_level: "high",
      reasons: ["Erreur snapshot: #{e.class}"],
      status: "error",
      error_message: e.message
    )
  end
end
