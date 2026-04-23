# app/models/btc_candle.rb
# frozen_string_literal: true

class BtcCandle < ApplicationRecord
  TIMEFRAMES = %w[1m 5m 15m 1h 4h 1d].freeze

  validates :market, presence: true
  validates :timeframe, presence: true, inclusion: { in: TIMEFRAMES }
  validates :open_time, presence: true
  validates :close_time, presence: true
  validates :open, :high, :low, :close, presence: true, numericality: true
  validates :volume, numericality: true, allow_nil: true
  validates :source, presence: true

  validate :ohlc_consistency
  validate :close_after_open

  scope :for_market, ->(market) { where(market: market) }
  scope :for_timeframe, ->(timeframe) { where(timeframe: timeframe) }
  scope :ordered, -> { order(open_time: :asc) }
  scope :recent_first, -> { order(open_time: :desc) }

  private

  def ohlc_consistency
    return if open.blank? || high.blank? || low.blank? || close.blank?

    values = [open.to_d, high.to_d, low.to_d, close.to_d]
    return unless high.to_d < values.max || low.to_d > values.min

    errors.add(:base, "OHLC incohérent")
  end

  def close_after_open
    return if open_time.blank? || close_time.blank?
    return if close_time > open_time

    errors.add(:close_time, "must be after open_time")
  end
end