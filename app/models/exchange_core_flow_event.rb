# frozen_string_literal: true

class ExchangeCoreFlowEvent < ApplicationRecord
  DIRECTIONS = %w[inflow outflow].freeze

  validates :block_height, presence: true
  validates :txid, presence: true
  validates :address, presence: true
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :amount_btc, numericality: { greater_than_or_equal_to: 0 }
end