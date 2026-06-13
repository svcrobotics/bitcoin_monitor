# frozen_string_literal: true

require "csv"
require "net/http"
require "uri"
require "bigdecimal"

module EconomicIndicators
  class FetchFredSeries
    FRED_CSV_URL = "https://fred.stlouisfed.org/graph/fredgraph.csv"
    MAX_RETRIES = 3

    def self.call(series_id:, code:, name:, since: 5.years.ago.to_date)
      new(series_id:, code:, name:, since:).call
    end

    def initialize(series_id:, code:, name:, since:)
      @series_id = series_id
      @code = code
      @name = name
      @since = since
    end

    def call
      csv_body = fetch_csv
      rows = CSV.parse(csv_body, headers: true)

      records = rows.map(&:to_h).filter_map do |row|
        raw_value = row[@series_id]

        next if raw_value.blank? || raw_value == "."

        observed_on = Date.parse(row["observation_date"])

        {
          code: @code,
          name: @name,
          source: "fred",
          observed_on: observed_on,
          value: BigDecimal(raw_value.to_s),
          raw_payload: {
            series_id: @series_id,
            observation_date: row["observation_date"],
            value: raw_value,
            url: fred_url
          },
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      return { ok: false, code: @code, imported: 0 } if records.empty?

      EconomicIndicator.upsert_all(
        records,
        unique_by: [:code, :observed_on]
      )

      latest = records.max_by { |record| record[:observed_on] }

      {
        ok: true,
        code: @code,
        imported: records.size,
        latest_observed_on: latest[:observed_on],
        latest_value: latest[:value].to_s,
        source: "fred"
      }
    end

    private

    def fetch_csv
      attempts = 0

      begin
        attempts += 1

        uri = URI(fred_url)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 60

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Tansa Economic Indicators/1.0"

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise "FRED HTTP error #{response.code}: #{response.body.to_s.first(200)}"
        end

        response.body
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
        retry if attempts < MAX_RETRIES

        raise "FRED timeout after #{attempts} attempts: #{e.class} #{e.message}"
      end
    end

    def fred_url
      params = URI.encode_www_form(
        id: @series_id,
        cosd: @since.to_s
      )

      "#{FRED_CSV_URL}?#{params}"
    end
  end
end