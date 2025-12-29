# frozen_string_literal: true
require "net/http"
require "json"

class BtcPrice
  class Error < StandardError; end

  COINGECKO_URL = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=eur"

  def self.eur
    Rails.cache.fetch("btc_eur_price", expires_in: 2.minutes) do
      uri = URI.parse(COINGECKO_URL)
      res = Net::HTTP.get_response(uri)
      raise Error, "Price HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body)
      price = json.dig("bitcoin", "eur")
      raise Error, "Price missing" if price.nil?

      price.to_d
    end
  rescue => e
    # fallback: si CoinGecko down, on ne casse pas la page
    Rails.logger.warn("BtcPrice.eur failed: #{e.class} #{e.message}")
    nil
  end
end
