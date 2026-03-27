# frozen_string_literal: true

class ExchangeOutflowBreakdown < ApplicationRecord
  self.table_name = "exchange_outflow_breakdowns"

  validates :day, :scope, :bucket, presence: true

  scope :for_day,   ->(day) { where(day: day) }
  scope :external,  -> { where(scope: "external") }
  scope :internal,  -> { where(scope: "internal") }
  scope :gross,     -> { where(scope: "gross") }

  def self.buckets_order
    %w[p2tr p2wpkh p2wsh p2sh p2pkh op_return unknown]
  end
end