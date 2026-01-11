# app/models/exchange_flow.rb
class ExchangeFlow < ApplicationRecord
  STATUSES = %w[green amber red].freeze

  validates :day, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }, allow_nil: true

  scope :recent, -> { order(day: :desc) }
end
