# frozen_string_literal: true
# app/services/price_sources/coinbase_daily.rb

require "net/http"
require "json"
require "date"

module PriceSources
  class CoinbaseDaily
    PAIR = "BTC-USD"

    def fetch_day(day)
      start_t = day.beginning_of_day.iso8601
      end_t   = day.end_of_day.iso8601

      uri = URI("https://api.exchange.coinbase.com/products/#{PAIR}/candles")
      uri.query = URI.encode_www_form(
        granularity: 86_400,
        start: start_t,
        end: end_t
      )

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "BitcoinMonitor"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      res = http.request(req)

      raise "Coinbase HTTP error #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      rows = JSON.parse(res.body)
      raise "Coinbase no data" if rows.blank?

      # format: [ time, low, high, open, close, volume ]
      r = rows.first

      {
        day: day,
        open:       r[3].to_d,
        high:       r[2].to_d,
        low:        r[1].to_d,
        close:      r[4].to_d,
        volume_btc: r[5].to_d
      }
    end
  end
end
