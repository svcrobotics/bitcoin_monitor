# frozen_string_literal: true

require "net/http"
require "json"

module FxSources
  class EurUsdDaily
    class << self
      # Retourne le taux "1 EUR = X USD" pour un jour donné.
      # Source: exchangerate.host
      def fetch_close(day)
        return nil if day.blank?

        uri = URI("https://api.exchangerate.host/#{day}?base=EUR&symbols=USD")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 8

        req = Net::HTTP::Get.new(uri)
        req["Accept"] = "application/json"

        res = http.request(req)
        return nil unless res.is_a?(Net::HTTPSuccess)

        json = JSON.parse(res.body)

        # Accepte différents formats possibles
        rate =
          json.dig("rates", "USD") ||
          json.dig("rates", :USD) ||
          json.dig("USD") ||
          json.dig(:USD)

        return nil if rate.blank?

        bd = BigDecimal(rate.to_s)
        return nil if bd <= 0

        bd
      rescue JSON::ParserError => e
        Rails.logger.warn("[FX] EurUsdDaily JSON parse error for #{day}: #{e.class} #{e.message}")
        nil
      rescue => e
        Rails.logger.warn("[FX] EurUsdDaily failed for #{day}: #{e.class} #{e.message}")
        nil
      end
    end
  end
end
