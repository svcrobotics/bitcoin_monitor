# frozen_string_literal: true
require "net/http"
require "json"
require "uri"

class CoingeckoClient
  BASE = "https://api.coingecko.com/api/v3"

  def btc_price_usd
    # Cache 60s (évite de spam l'API)
    Rails.cache.fetch("coingecko:btc:price_usd", expires_in: 60.seconds) do
      uri = URI("#{BASE}/simple/price?ids=bitcoin&vs_currencies=usd")
      res = Net::HTTP.get_response(uri)

      raise "CoinGecko HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body)
      json.dig("bitcoin", "usd")
    end
  rescue => e
    Rails.logger.warn("[CoingeckoClient] btc_price_usd failed: #{e.class} #{e.message}")
    nil
  end
end
