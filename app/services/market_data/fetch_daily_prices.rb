# app/services/market_data/fetch_daily_prices.rb
require "net/http"
require "json"
require "uri"

module MarketData
  class FetchDailyPrices
    class Error < StandardError; end

    COINGECKO_BASE = "https://api.coingecko.com/api/v3"

    # days: "max" ou un nombre (ex: 730)
    # vs_currency: "usd" (on commence en USD)
    def initialize(days: 730, vs_currency: "usd", logger: Rails.logger)
      @days        = days
      @vs_currency = vs_currency
      @logger      = logger
    end

    # Retourne un hash de stats: { inserted:, updated:, total_rows:, from:, to: }
    def call
      data = fetch_market_chart

      prices = data.fetch("prices")
      raise Error, "CoinGecko: no prices returned" if prices.blank?

      upserted_days = upsert_prices(prices)

      {
        inserted: upserted_days[:inserted],
        updated:  upserted_days[:updated],
        total_rows: BtcPriceDay.count,
        from: upserted_days[:from],
        to: upserted_days[:to]
      }
    rescue Error => e
      # Fallback spécial CoinGecko public (fenêtre historique limitée)
      if e.message.include?("error_code\":10012") || e.message.downcase.include?("allowed time range")
        @logger.warn("[MarketData::FetchDailyPrices] CoinGecko limit hit, retrying with days=365")
        @days = 365
        retry
      end
      raise
    end

    private

    def fetch_market_chart
      uri = URI.parse("#{COINGECKO_BASE}/coins/bitcoin/market_chart")
      uri.query = URI.encode_www_form(vs_currency: @vs_currency, days: @days)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      req = Net::HTTP::Get.new(uri.request_uri)
      req["Accept"]     = "application/json"
      req["User-Agent"] = "BitcoinMonitor/1.0 (Rails)"

      res = http.request(req)

      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "CoinGecko HTTP #{res.code}: #{res.body.to_s[0, 200]}"
      end

      JSON.parse(res.body)
    rescue JSON::ParserError => e
      raise Error, "CoinGecko JSON parse error: #{e.message}"
    rescue => e
      raise Error, "CoinGecko request failed: #{e.class} - #{e.message}"
    end

    def upsert_prices(prices)
      # CoinGecko renvoie souvent plusieurs points; on veut 1 close par jour.
      # Stratégie simple: on garde le dernier prix rencontré pour chaque day.
      by_day = {}

      prices.each do |(ts_ms, price)|
        day = Time.at(ts_ms.to_f / 1000).utc.to_date
        by_day[day] = price.to_d
      end

      days_sorted = by_day.keys.sort
      from_day = days_sorted.first
      to_day   = days_sorted.last

      # On prépare les lignes à upsert
      now = Time.current
      rows = days_sorted.map do |day|
        {
          day: day,
          close_usd: by_day.fetch(day),
          source: "coingecko",
          created_at: now,
          updated_at: now
        }
      end

      # Avant/après pour stats inserted/updated
      existing_days = BtcPriceDay.where(day: days_sorted).pluck(:day).to_h { |d| [d, true] }

      # Rails 6+ : upsert_all
      # unique_by doit matcher l'index unique sur day
      BtcPriceDay.upsert_all(rows, unique_by: :index_btc_price_days_on_day)

      inserted = days_sorted.count { |d| !existing_days.key?(d) }
      updated  = days_sorted.count - inserted

      @logger.info("[MarketData::FetchDailyPrices] days=#{days_sorted.size} inserted=#{inserted} updated=#{updated} from=#{from_day} to=#{to_day}")

      { inserted: inserted, updated: updated, from: from_day, to: to_day }
    end
  end
end
