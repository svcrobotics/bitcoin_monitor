# app/services/price_ticker.rb
require "net/http"
require "json"

class PriceTicker
  def self.btc_eur
    Rails.cache.fetch("price:btc_eur", expires_in: 5.minutes) do
      url = URI("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=eur")
      res = Net::HTTP.get_response(url)
      return nil unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body)
      json.dig("bitcoin", "eur")
    rescue
      nil
    end
  end
end
