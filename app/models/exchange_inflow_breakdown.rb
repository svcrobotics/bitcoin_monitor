# frozen_string_literal: true

class ExchangeInflowBreakdown < ApplicationRecord
  SCOPES = %w[inflow custody].freeze

  validates :day, presence: true
  validates :scope, presence: true, inclusion: { in: SCOPES }
  validates :min_occ, numericality: { only_integer: true, greater_than: 0 }

  def buckets_hash
    {
      lt10: lt10_btc.to_d,
      b10_99: b10_99_btc.to_d,
      b100_499: b100_499_btc.to_d,
      b500p: b500p_btc.to_d,
      total: total_btc.to_d
    }
  end
end