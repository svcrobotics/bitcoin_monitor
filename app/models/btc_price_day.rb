class BtcPriceDay < ApplicationRecord
  validates :day, presence: true, uniqueness: true
  validates :close_usd, presence: true, numericality: true
  validates :source, presence: true
end
