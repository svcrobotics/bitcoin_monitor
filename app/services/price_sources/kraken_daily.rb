# frozen_string_literal: true
# app/services/price_sources/kraken_daily.rb

require "net/http"
require "json"
require "date"

module PriceSources
  class KrakenDaily
    PAIR = "XBTUSD"

    # Récupère la bougie daily BTC/USD pour une date donnée.
    #
    # Stratégie "robuste" :
    # - on demande des bougies daily (interval 1440)
    # - on met since 2 jours avant pour être sûr de recevoir la bougie cible
    # - Kraken peut renvoyer la paire sous une clé interne (ex: "XXBTZUSD")
    # - on sélectionne ensuite la bougie dont le timestamp tombe dans la journée voulue
    def fetch_day(day)
      since = (day - 2).to_time.to_i

      uri = URI("https://api.kraken.com/0/public/OHLC")
      uri.query = URI.encode_www_form(
        pair: PAIR,
        interval: 1440,
        since: since
      )

      res = Net::HTTP.get_response(uri)
      raise "Kraken HTTP error #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body)
      raise "Kraken API error: #{json['error'].inspect}" if json["error"].present? && json["error"].any?

      result = json["result"] || {}
      raise "Kraken no result" if result.blank?

      # Kraken renvoie souvent une clé de paire différente de "XBTUSD" (ex: "XXBTZUSD").
      pair_key = (result.keys - ["last"]).first
      rows = result[pair_key]
      raise "Kraken no data" if rows.blank?

      start_ts = day.beginning_of_day.to_i
      end_ts   = day.end_of_day.to_i

      # format: [time, open, high, low, close, vwap, volume, count]
      candle = rows.map { |r| Array(r) }
                   .find { |r| r[0].to_i >= start_ts && r[0].to_i <= end_ts }

      # Si Kraken timestamp la bougie au début du jour UTC, elle peut tomber légèrement hors plage locale.
      # Fallback : on prend la bougie la plus proche du start_ts.
      candle ||= rows.map { |r| Array(r) }
                     .min_by { |r| (r[0].to_i - start_ts).abs }

      raise "Kraken no candle for #{day}" if candle.blank?

      {
        day: day,
        open:       candle[1].to_d,
        high:       candle[2].to_d,
        low:        candle[3].to_d,
        close:      candle[4].to_d,
        volume_btc: candle[6].to_d
      }
    end
  end
end
