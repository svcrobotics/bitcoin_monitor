class TradeSimulation < ApplicationRecord
  validates :buy_day, :sell_day, presence: true
  validates :btc_amount, numericality: { greater_than: 0 }
  validates :buy_fee_pct, :sell_fee_pct, :slippage_pct, numericality: { greater_than_or_equal_to: 0 }
  validates :buy_fee_fixed_eur, :sell_fee_fixed_eur, numericality: { greater_than_or_equal_to: 0 }

  validate :sell_after_buy
  has_many :points, class_name: "TradeSimulationPoint", dependent: :delete_all

  private

  def sell_after_buy
    return if buy_day.blank? || sell_day.blank?
    errors.add(:sell_day, "doit être après la date d'achat") if sell_day < buy_day
  end
end
