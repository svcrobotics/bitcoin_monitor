module BitcoinHelper
  SATS_PER_BTC = 100_000_000

  def format_sats(sats)
    number_with_delimiter(sats.to_i, delimiter: " ")
  end

  def format_btc_precise(btc)
    format("%.8f", btc.to_d)
  end

  def format_btc_from_sats(sats)
    format_btc_precise(sats.to_d / SATS_PER_BTC)
  end

  def format_eur(amount)
    number_to_currency(amount, unit: "€", format: "%n %u", precision: 2)
  end
end
