class TradeSimulationPoint < ApplicationRecord
  belongs_to :trade_simulation
  validates :day, presence: true
end
