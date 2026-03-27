# frozen_string_literal: true

require "bigdecimal"

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
    raise PriceMissing, "Date d’achat absente" if @sim.buy_day.blank?
    raise PriceMissing, "Date de vente absente (position ouverte)" if @sim.sell_day.blank?

    buy_price  = close_eur_for!(@sim.buy_day)
    sell_price = close_eur_for!(@sim.sell_day)

    btc          = dec!(@sim.btc_amount, "btc_amount manquant") # strict
    slippage_pct = dec0(@sim.slippage_pct)                      # nil => 0

    buy_gross = btc * buy_price
    buy_fees  = pct(buy_gross, dec0(@sim.buy_fee_pct)) +
                dec0(@sim.buy_fee_fixed_eur) +
                pct(buy_gross, slippage_pct)
    buy_total = buy_gross + buy_fees

    sell_gross = btc * sell_price
    sell_fees  = pct(sell_gross, dec0(@sim.sell_fee_pct)) +
                 dec0(@sim.sell_fee_fixed_eur) +
                 pct(sell_gross, slippage_pct)
    sell_net   = sell_gross - sell_fees

    pnl     = sell_net - buy_total
    pnl_pct = buy_total.zero? ? 0.to_d : (pnl / buy_total) * 100

    Result.new(
      buy_price: buy_price, sell_price: sell_price,
      buy_gross: buy_gross, buy_fees: buy_fees, buy_total: buy_total,
      sell_gross: sell_gross, sell_fees: sell_fees, sell_net: sell_net,
      pnl: pnl, pnl_pct: pnl_pct
    )
  end

  private

  def close_eur_for!(day)
    row = BtcPriceDay.find_by(day: day)
    raise PriceMissing, "Prix BTC manquant pour #{day}" if row.nil?

    # ✅ cas nominal
    return BigDecimal(row.close_eur.to_s) if row.close_eur.present?

    # ✅ fallback: si EUR absent mais USD présent, on convertit via un taux courant (approx)
    if row.close_usd.present?
      usd = BigDecimal(row.close_usd.to_s)
      rate = current_usd_per_eur_rate # USD/EUR

      if rate && rate > 0
        eur = (usd / rate).round(8)
        Rails.logger.warn("[trade_simulator] close_eur missing for #{day}, computed fallback from USD using current fx rate: #{eur.to_s('F')}")
        # Option: persister pour éviter de recalculer
        row.update_columns(close_eur: eur)
        return eur
      end
    end

    raise PriceMissing, "Prix BTC (EUR) manquant pour #{day} (close_usd=#{row.close_usd.inspect})"
  end

  # USD/EUR courant (approx) via CoinGecko "simple/price"
  def current_usd_per_eur_rate
    # si tu as déjà un client coingecko, utilise-le ici.
    # Exemple “simple” sans dépendre d’un service existant :
    require "net/http"
    require "json"

    url = URI("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd,eur")
    res = Net::HTTP.get_response(url)
    return nil unless res.is_a?(Net::HTTPSuccess)

    json = JSON.parse(res.body)
    usd = json.dig("bitcoin", "usd").to_f
    eur = json.dig("bitcoin", "eur").to_f
    return nil if usd <= 0 || eur <= 0

    BigDecimal((usd / eur).to_s) # USD/EUR
  rescue => e
    Rails.logger.warn("[trade_simulator] fx rate fallback failed: #{e.class} #{e.message}")
    nil
  end

  # nil => 0 (pour fees/slippage)
  def dec0(x)
    x.present? ? BigDecimal(x.to_s) : 0.to_d
  end

  # strict (pour btc_amount)
  def dec!(x, msg)
    raise PriceMissing, msg if x.blank?
    BigDecimal(x.to_s)
  end

  # pct_value attendu en "pourcent" (ex: 0.5 => 0.5%)
  def pct(amount, pct_value)
    amount * (pct_value / 100)
  end
end
