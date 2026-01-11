# frozen_string_literal: true

class BtcPriceDayBuilder
  SOURCES = {
    kraken:   PriceSources::KrakenDaily.new,
    coinbase: PriceSources::CoinbaseDaily.new,
    bitstamp: PriceSources::BitstampDaily.new
  }.freeze

  def self.call(day:)
    new(day: day).call
  end

  def initialize(day:)
    @day = day
  end

  def call
    samples = {}

    SOURCES.each do |name, client|
      samples[name] = client.fetch_day(@day)
    rescue => e
      samples[name] = { error: e.message }
    end

    good = samples.values.select { |h| h.is_a?(Hash) && h[:close].present? }
    raise "Aucune source de prix disponible pour #{@day}" if good.empty?

    row = BtcPriceDay.find_or_initialize_by(day: @day)

    row.open_usd   = median(good.map { |x| x[:open] })
    row.high_usd   = median(good.map { |x| x[:high] })
    row.low_usd    = median(good.map { |x| x[:low] })
    row.close_usd  = median(good.map { |x| x[:close] })
    row.volume_btc = median(good.map { |x| x[:volume_btc] }.compact)

    row.source       = "composite"
    row.sources_json = samples if row.respond_to?(:sources_json=)
    row.computed_at  = Time.current if row.respond_to?(:computed_at=)

    row.save!
    row
  end

  private

  def median(values)
    arr = Array(values).compact.map(&:to_d).sort
    return nil if arr.empty?
    mid = arr.length / 2
    arr.length.odd? ? arr[mid] : ((arr[mid - 1] + arr[mid]) / 2)
  end
end
