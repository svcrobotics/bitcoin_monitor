# app/services/market_data/fetch_daily_prices.rb
require "net/http"
require "json"
require "uri"

module MarketData
  class FetchDailyPrices
    class Error < StandardError; end

    COINGECKO_BASE = "https://api.coingecko.com/api/v3"

    # days: "max" ou un nombre (ex: 730)
    # vs_currencies: ["usd","eur"] par défaut (remplit close_usd + close_eur)
    #
    # Compat: si tu passes vs_currency: "usd" (ancien usage), ça marche aussi.
    def initialize(days: 730, vs_currencies: %w[usd eur], vs_currency: nil, logger: Rails.logger)
      @days        = days
      @logger      = logger

      # compat ancienne option vs_currency
      if vs_currency.present?
        @vs_currencies = [vs_currency.to_s.downcase]
      else
        @vs_currencies = Array(vs_currencies).map { |x| x.to_s.downcase }.uniq
      end

      @vs_currencies = %w[usd eur] if @vs_currencies.empty?
    end

    # Retourne un hash de stats: { inserted:, updated:, total_rows:, from:, to:, currencies: [...] }
    def call
      # 1) Fetch + upsert USD si demandé
      usd_stats = nil
      if @vs_currencies.include?("usd")
        usd_prices = fetch_prices_by_day("usd")
        usd_stats  = upsert_by_day(usd_prices, column: :close_usd, source: "coingecko")
      end

      # 2) Fetch + upsert EUR si demandé
      eur_stats = nil
      if @vs_currencies.include?("eur")
        eur_prices = fetch_prices_by_day("eur")
        eur_stats  = upsert_by_day(eur_prices, column: :close_eur, source: "coingecko")
      end

      # Stats globales (union)
      from_day = [usd_stats&.dig(:from), eur_stats&.dig(:from)].compact.min
      to_day   = [usd_stats&.dig(:to), eur_stats&.dig(:to)].compact.max

      inserted = (usd_stats&.dig(:inserted).to_i > 0 ? usd_stats[:inserted].to_i : 0)
      inserted = [inserted, eur_stats&.dig(:inserted).to_i].max # estimation: les "inserted" sont surtout sur USD
      updated  = (usd_stats&.dig(:updated).to_i) + (eur_stats&.dig(:updated).to_i)

      {
        inserted: inserted,
        updated: updated,
        total_rows: BtcPriceDay.count,
        from: from_day,
        to: to_day,
        currencies: @vs_currencies
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

    def fetch_prices_by_day(vs_currency)
      data = fetch_market_chart(vs_currency)

      prices = data.fetch("prices")
      raise Error, "CoinGecko: no prices returned (vs=#{vs_currency})" if prices.blank?

      # CoinGecko renvoie souvent plusieurs points; on veut 1 close par jour.
      # Stratégie: on garde le dernier prix rencontré pour chaque day.
      by_day = {}
      prices.each do |(ts_ms, price)|
        day = Time.at(ts_ms.to_f / 1000).utc.to_date
        by_day[day] = price.to_d
      end

      by_day
    end

    def fetch_market_chart(vs_currency)
      uri = URI.parse("#{COINGECKO_BASE}/coins/bitcoin/market_chart")
      uri.query = URI.encode_www_form(vs_currency: vs_currency, days: @days)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      req = Net::HTTP::Get.new(uri.request_uri)
      req["Accept"]     = "application/json"
      req["User-Agent"] = "BitcoinMonitor/1.0 (Rails)"

      res = http.request(req)

      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "CoinGecko HTTP #{res.code} (vs=#{vs_currency}): #{res.body.to_s[0, 200]}"
      end

      JSON.parse(res.body)
    rescue JSON::ParserError => e
      raise Error, "CoinGecko JSON parse error (vs=#{vs_currency}): #{e.message}"
    rescue => e
      raise Error, "CoinGecko request failed (vs=#{vs_currency}): #{e.class} - #{e.message}"
    end

    # Upsert une colonne (close_usd OU close_eur) sans écraser l’autre.
    def upsert_by_day(by_day, column:, source:)
      days_sorted = by_day.keys.sort
      return { inserted: 0, updated: 0, from: nil, to: nil } if days_sorted.empty?

      from_day = days_sorted.first
      to_day   = days_sorted.last

      now = Time.current

      rows = days_sorted.map do |day|
        {
          day: day,
          column => by_day.fetch(day),
          source: source,
          created_at: now,
          updated_at: now
        }
      end

      # stats inserted/updated (approx) sur cette passe
      existing_days = BtcPriceDay.where(day: days_sorted).pluck(:day).to_h { |d| [d, true] }

      BtcPriceDay.upsert_all(rows, unique_by: :index_btc_price_days_on_day)

      inserted = days_sorted.count { |d| !existing_days.key?(d) }
      updated  = days_sorted.count - inserted

      @logger.info("[MarketData::FetchDailyPrices] vs=#{column} days=#{days_sorted.size} inserted=#{inserted} updated=#{updated} from=#{from_day} to=#{to_day}")

      { inserted: inserted, updated: updated, from: from_day, to: to_day }
    end
  end
end
