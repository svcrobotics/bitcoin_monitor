class Brc20Balance < ApplicationRecord
  belongs_to :brc20_token

  scope :for_tick, ->(tick) { where(tick: tick.downcase) }

  # Tri naïf : si tu restes dans des valeurs raisonnables
  scope :by_balance_desc, -> {
    order(Arel.sql("CAST(balance AS INTEGER) DESC"))
  }
end
