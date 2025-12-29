module MoneyHelper
  def eur_fr(amount, precision: 0)
    return "" if amount.nil?

    number_to_currency(
      amount,
      unit: "€",
      format: "%n %u",
      delimiter: ".",
      separator: ",",
      precision: precision
    )
  end
end
