# frozen_string_literal: true
# app/services/price_sources/bitstamp_daily.rb

require "net/http"
require "json"
require "date"

module PriceSources
  class BitstampDaily
    PAIR = "btcusd"

    # Récupère la bougie daily BTC/USD pour une date donnée.
    #
    # Stratégie robuste :
    # - Bitstamp OHLC est parfois strict sur start/end -> on demande un range plus large
    # - on ajoute limit pour éviter un payload énorme
    # - on sélectionne ensuite la bougie qui correspond à la journée voulue
    def fetch_day(day)
      # On élargit la fenêtre pour être sûr de recevoir la bougie du jour,
      # et on filtre ensuite.
      start_ts = (day - 3).beginning_of_day.to_i
      end_ts   = (day + 1).end_of_day.to_i

      uri = URI("https://www.bitstamp.net/api/v2/ohlc/#{PAIR}/")
      uri.query = URI.encode_www_form(
        step: 86_400,   # daily
        start: start_ts,
        end: end_ts,
        limit: 10
      )

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "BitcoinMonitor"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      res = http.request(req)

      raise "Bitstamp HTTP error #{res.code} body=#{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body)
      rows = json.dig("data", "ohlc")
      raise "Bitstamp no data" if rows.blank?

      target_start = day.beginning_of_day.to_i
      target_end   = day.end_of_day.to_i

      # Bitstamp retourne des timestamps en string
      candle = rows.find do |r|
        t = r["timestamp"].to_i
        t >= target_start && t <= target_end
      end

      # fallback : bougie la plus proche
      candle ||= rows.min_by { |r| (r["timestamp"].to_i - target_start).abs }

      raise "Bitstamp no candle for #{day}" if candle.blank?

      {
        day: day,
        open:       candle["open"].to_d,
        high:       candle["high"].to_d,
        low:        candle["low"].to_d,
        close:      candle["close"].to_d,
        volume_btc: candle["volume"].to_d
      }
    end
  end
end
