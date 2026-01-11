# app/models/exchange_true_flow.rb
class ExchangeTrueFlow < ApplicationRecord
  STATUSES = %w[green amber red].freeze
  validates :day, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }, allow_nil: true
  scope :recent, -> { order(day: :desc) }
end
