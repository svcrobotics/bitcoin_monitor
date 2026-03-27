# app/models/trade_simulation.rb
class TradeSimulation < ApplicationRecord
  STATUSES = %w[open closed].freeze

  before_validation :derive_btc_amount_from_buy_eur

  has_many :points, class_name: "TradeSimulationPoint", dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }, allow_nil: true
  validates :buy_day, presence: true
  validates :sell_day, presence: true, if: :closed?

  # ✅ EUR ou BTC : il faut au moins l’un des deux
  validate :buy_amount_presence

  # ✅ BTC est désormais optionnel (si buy_amount_eur est présent, il sera dérivé)
  validates :btc_amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :buy_amount_eur, numericality: { greater_than: 0 }, allow_nil: true

  validates :buy_fee_pct, :sell_fee_pct, :slippage_pct,
           numericality: { greater_than_or_equal_to: 0 }
  validates :buy_fee_fixed_eur, :sell_fee_fixed_eur,
           numericality: { greater_than_or_equal_to: 0 }

  validate :sell_after_buy, if: -> { buy_day.present? && sell_day.present? }

  def open?
    status.to_s == "open" || status.nil?
  end

  def closed?
    status.to_s == "closed"
  end

  private

  def buy_amount_presence
    if buy_amount_eur.blank? && btc_amount.blank?
      errors.add(:buy_amount_eur, "doit être renseigné (ou BTC)")
    end
  end

  def sell_after_buy
    errors.add(:sell_day, "doit être après la date d'achat") if sell_day < buy_day
  end

  def derive_btc_amount_from_buy_eur
    # ✅ ne rien faire si EUR non fourni
    return if buy_amount_eur.blank? || buy_day.blank?

    row = BtcPriceDay.find_by(day: buy_day)
    return if row.nil? || row.close_eur.blank?

    eur   = BigDecimal(buy_amount_eur.to_s)
    price = BigDecimal(row.close_eur.to_s)
    return if price <= 0

    # Montant brut converti en BTC (frais/slippage restent à part)
    self.btc_amount = (eur / price).round(8)
  end
end
