class BtcPriceDay < ApplicationRecord
  validates :day, presence: true
  validates :close_usd, presence: true, numericality: true
  validates :source, presence: true
  validates :source, uniqueness: { scope: :day }

  scope :ordered, -> { order(day: :asc) }
  scope :recent_first, -> { order(day: :desc) }
  scope :with_close, -> { where.not(close_usd: nil) }
  scope :composite, -> { where(source: "composite") }
end