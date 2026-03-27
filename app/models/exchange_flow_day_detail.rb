class ExchangeFlowDayDetail < ApplicationRecord
  validates :day, presence: true, uniqueness: true
end