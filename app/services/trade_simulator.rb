# frozen_string_literal: true

class TradeSimulator
  Result = Struct.new(
    :buy_price, :sell_price,
    :buy_gross, :buy_fees, :buy_total,
    :sell_gross, :sell_fees, :sell_net,
    :pnl, :pnl_pct,
    keyword_init: true
  )

  class PriceMissing < StandardError; end

  def self.call(sim) = new(sim).call

  def initialize(sim) = @sim = sim

  def call
    buy_price  = close_usd_for!(@sim.buy_day)
    sell_price = close_usd_for!(@sim.sell_day)

    btc = dec(@sim.btc_amount)
    slippage_pct = dec(@sim.slippage_pct)

    buy_gross = btc * buy_price
    buy_fees  = pct(buy_gross, @sim.buy_fee_pct) + dec(@sim.buy_fee_fixed_eur) + pct(buy_gross, slippage_pct)
    buy_total = buy_gross + buy_fees

    sell_gross = btc * sell_price
    sell_fees  = pct(sell_gross, @sim.sell_fee_pct) + dec(@sim.sell_fee_fixed_eur) + pct(sell_gross, slippage_pct)
    sell_net   = sell_gross - sell_fees

    pnl = sell_net - buy_total
    pnl_pct = buy_total.zero? ? 0.to_d : (pnl / buy_total) * 100

    Result.new(
      buy_price: buy_price, sell_price: sell_price,
      buy_gross: buy_gross, buy_fees: buy_fees, buy_total: buy_total,
      sell_gross: sell_gross, sell_fees: sell_fees, sell_net: sell_net,
      pnl: pnl, pnl_pct: pnl_pct
    )
  end

  private

  def close_usd_for!(day)
    row = BtcPriceDay.find_by(day: day)
    raise PriceMissing, "Prix BTC (USD) manquant pour #{day}" if row.nil?
    dec(row.close_usd)
  end

  def dec(x) = BigDecimal(x.to_s)
  def pct(amount, pct_value) = amount * (dec(pct_value) / 100)
end
