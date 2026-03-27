# app/models/exchange_address.rb
class ExchangeAddress < ApplicationRecord
  validates :address, presence: true, uniqueness: true

  scope :with_min_occurrences, ->(min) { where("occurrences >= ?", min.to_i) }
  scope :with_min_confidence,  ->(min) { where("confidence >= ?", min.to_i) }

  scope :operational, lambda {
    min_occ  = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "20")) rescue 20
    min_conf = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_CONFIDENCE", "60")) rescue 60

    where("occurrences >= ? AND confidence >= ?", min_occ, min_conf)
  }

  scope :scannable, lambda {
    min_occ  = Integer(ENV.fetch("EXCHANGE_ADDR_SCAN_MIN_OCC", "50")) rescue 50
    min_conf = Integer(ENV.fetch("EXCHANGE_ADDR_SCAN_MIN_CONFIDENCE", "80")) rescue 80

    where("occurrences >= ? AND confidence >= ?", min_occ, min_conf)
  }
end