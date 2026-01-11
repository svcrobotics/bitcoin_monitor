class PriceZone < ApplicationRecord
  KINDS = %w[support resistance].freeze

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :low_usd, :high_usd, presence: true, numericality: true
  validates :strength, presence: true, numericality: { only_integer: true }
  validates :touches_count, presence: true, numericality: { only_integer: true }
  validates :timeframe, presence: true
  validates :computed_at, presence: true

  scope :latest, -> { order(computed_at: :desc) }
  scope :for_timeframe, ->(tf) { where(timeframe: tf) }
  scope :supports, -> { where(kind: "support") }
  scope :resistances, -> { where(kind: "resistance") }

  def self.for_dashboard(timeframe: "1y_daily", price_now:)
    price = price_now.to_d

    base = where(timeframe: timeframe)

    supports = base.where(kind: "support")
    resist   = base.where(kind: "resistance")

    min_strength = 60

    best_support =
      supports.where("high_usd <= ?", price).where("strength >= ?", min_strength)
              .order(Arel.sql("high_usd DESC, strength DESC")).first ||
      supports.where("high_usd <= ?", price)
              .order(Arel.sql("high_usd DESC, strength DESC")).first

    best_resistance =
      resist.where("low_usd >= ?", price).where("strength >= ?", min_strength)
            .order(Arel.sql("low_usd ASC, strength DESC")).first ||
      resist.where("low_usd >= ?", price)
            .order(Arel.sql("low_usd ASC, strength DESC")).first

    bonus = []

    if best_support&.strength.to_i >= 70
      second_support = supports
        .where("high_usd <= ?", price)
        .where("strength >= ?", 70)
        .where.not(id: best_support.id)
        .order(Arel.sql("high_usd DESC, strength DESC"))
        .first
      bonus << second_support if second_support&.strength.to_i >= 70
    end

    if best_resistance&.strength.to_i >= 70
      second_resistance = resist
        .where("low_usd >= ?", price)
        .where("strength >= ?", 70)
        .where.not(id: best_resistance&.id)
        .order(Arel.sql("low_usd ASC, strength DESC"))
        .first
      bonus << second_resistance if second_resistance&.strength.to_i >= 70
    end

    { support: best_support, resistance: best_resistance, bonus: bonus.compact.uniq }
  end

end
