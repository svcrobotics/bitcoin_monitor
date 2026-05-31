# frozen_string_literal: true

class TradeSimulationCurveBuilder
  def self.call(sim)
    new(sim).call
  end

  def initialize(sim)
    @sim = sim
  end

  def call
    from = @sim.buy_day
    return if from.blank?

    last_price_day = BtcPriceDay.maximum(:day)
    return if last_price_day.blank?

    logical_to =
      if @sim.respond_to?(:closed?) && @sim.closed?
        @sim.sell_day
      else
        Date.current
      end
    return if logical_to.blank?

    to = [logical_to, last_price_day].min
    return if from > to

    price_rows =
      BtcPriceDay
        .where(day: from..to)
        .order(:day)
        .pluck(:day, :close_eur)
        .select { |_day, close_eur| close_eur.present? }

    return if price_rows.empty?

    buy_price = close_eur_for!(from)
    btc = dec!(@sim.btc_amount, "btc_amount manquant")
    slippage_pct = dec0(@sim.slippage_pct)

    buy_gross = btc * buy_price
    buy_fees =
      pct(buy_gross, dec0(@sim.buy_fee_pct)) +
      dec0(@sim.buy_fee_fixed_eur) +
      pct(buy_gross, slippage_pct)

    buy_total = buy_gross + buy_fees
    now = Time.current

    rows =
      price_rows.map do |day, close_eur|
        sell_price = BigDecimal(close_eur.to_s)
        sell_gross = btc * sell_price
        sell_fees =
          pct(sell_gross, dec0(@sim.sell_fee_pct)) +
          dec0(@sim.sell_fee_fixed_eur) +
          pct(sell_gross, slippage_pct)

        sell_net = sell_gross - sell_fees
        pnl = sell_net - buy_total
        pnl_pct = buy_total.zero? ? 0.to_d : (pnl / buy_total) * 100

        {
          trade_simulation_id: @sim.id,
          day: day,
          price_usd: close_eur,
          net_usd: sell_net,
          pnl_usd: pnl,
          pnl_pct: pnl_pct,
          created_at: now,
          updated_at: now
        }
      end

    TradeSimulationPoint.upsert_all(
      rows,
      unique_by: %i[trade_simulation_id day]
    )
  end

  private

  def close_eur_for!(day)
    close_eur = BtcPriceDay.where(day: day).pick(:close_eur)
    raise TradeSimulator::PriceMissing, "Prix BTC manquant pour #{day}" if close_eur.blank?

    BigDecimal(close_eur.to_s)
  end

  def dec0(x)
    x.present? ? BigDecimal(x.to_s) : 0.to_d
  end

  def dec!(x, msg)
    raise TradeSimulator::PriceMissing, msg if x.blank?

    BigDecimal(x.to_s)
  end

  def pct(amount, pct_value)
    amount * (pct_value / 100)
  end
end