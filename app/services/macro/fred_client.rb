# app/services/macro/fred_client.rb
require "net/http"
require "json"

module Macro
  class FredClient
    BASE_URL = "https://api.stlouisfed.org/fred/series/observations"

    def observations(series_id:)
      uri = URI(BASE_URL)
      uri.query = URI.encode_www_form(
        series_id: series_id,
        api_key: ENV.fetch("FRED_API_KEY"),
        file_type: "json"
      )

      response = Net::HTTP.get_response(uri)
      raise "FRED error #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body).fetch("observations")
    end
  end
end
