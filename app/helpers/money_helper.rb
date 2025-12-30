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

  def eur_human(amount)
    return "" if amount.nil?

    v = amount.to_d.abs

    if v >= 1_000_000_000
      billions = (v / 1_000_000_000).round(1)
      "≈ #{billions.to_s.tr('.', ',')} milliards €"
    elsif v >= 1_000_000
      millions = (v / 1_000_000).round(1)
      "≈ #{millions.to_s.tr('.', ',')} millions €"
    elsif v >= 1_000
      "≈ #{number_with_delimiter(v.to_i, delimiter: ' ')} €"
    else
      eur_fr(v, precision: 0)
    end
  end
end
