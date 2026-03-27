class ExchangeFlowDay < ApplicationRecord
  validates :day, presence: true, uniqueness: true
end