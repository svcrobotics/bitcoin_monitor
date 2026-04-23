# app/services/btc/providers/intraday/binance_provider.rb
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Btc
  module Providers
    module Intraday
      class BinanceProvider
        BASE_URL = "https://data-api.binance.vision".freeze

        INTERVAL_MAPPING = {
          "1m" => "1m",
          "5m" => "5m",
          "15m" => "15m",
          "1h" => "1h",
          "4h" => "4h",
          "1d" => "1d"
        }.freeze

        MARKET_MAPPING = {
          "btcusd" => "BTCUSDT",
          "btceur" => "BTCEUR"
        }.freeze

        class Error < StandardError; end

        class << self
          def fetch_klines(market:, timeframe:, start_time: nil, end_time: nil, limit: 500)
            new.fetch_klines(
              market: market,
              timeframe: timeframe,
              start_time: start_time,
              end_time: end_time,
              limit: limit
            )
          end
        end

        def fetch_klines(market:, timeframe:, start_time: nil, end_time: nil, limit: 500)
          symbol = MARKET_MAPPING.fetch(market) do
            raise Error, "Unsupported market: #{market}"
          end

          interval = INTERVAL_MAPPING.fetch(timeframe) do
            raise Error, "Unsupported timeframe: #{timeframe}"
          end

          uri = URI("#{BASE_URL}/api/v3/klines")
          params = {
            symbol: symbol,
            interval: interval,
            limit: normalize_limit(limit)
          }

          params[:startTime] = to_millis(start_time) if start_time.present?
          params[:endTime]   = to_millis(end_time) if end_time.present?

          uri.query = URI.encode_www_form(params)

          response = Net::HTTP.get_response(uri)
          raise Error, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          payload = JSON.parse(response.body)
          raise Error, "Unexpected payload" unless payload.is_a?(Array)

          payload.map do |row|
            # Binance kline format:
            # [
            #   0 open time,
            #   1 open,
            #   2 high,
            #   3 low,
            #   4 close,
            #   5 volume,
            #   6 close time,
            #   7 quote asset volume,
            #   8 number of trades,
            #   9 taker buy base,
            #   10 taker buy quote,
            #   11 ignore
            # ]
            {
              market: market,
              timeframe: timeframe,
              open_time: Time.at(row[0].to_i / 1000).utc,
              open: row[1].to_d,
              high: row[2].to_d,
              low: row[3].to_d,
              close: row[4].to_d,
              volume: row[5].to_d,
              close_time: Time.at(row[6].to_i / 1000).utc,
              trades_count: row[8].to_i,
              source: "binance"
            }
          end
        end

        private

        def normalize_limit(limit)
          value = limit.to_i
          value = 500 if value <= 0
          [value, 1000].min
        end

        def to_millis(value)
          value.to_time.utc.to_i * 1000
        end
      end
    end
  end
end