# frozen_string_literal: true

module Btc
  class DailyHistoryQuery
    ALLOWED_RANGES = {
      "7d" => 7,
      "30d" => 30,
      "1y" => 365
    }.freeze

    class << self
      def call(range: "30d")
        new(range: range).call
      end
    end

    def initialize(range: "30d")
      @range = ALLOWED_RANGES.key?(range) ? range : "30d"
    end

    def call
      days = ALLOWED_RANGES.fetch(@range)
      to_day = Date.current - 1
      from_day = to_day - (days - 1)

      rows = BtcPriceDay
        .where(day: from_day..to_day)
        .with_close
        .order(:day)
        .pluck(:day, :open_usd, :high_usd, :low_usd, :close_usd, :source)

      rows_by_day = rows.group_by { |(day, _open, _high, _low, _close, _source)| day }

      rows_by_day.keys.sort.filter_map do |day|
        day_rows = rows_by_day[day]

        best = day_rows.find { |(_d, _o, _h, _l, _c, src)| src.to_s == "composite" }
        best ||= day_rows.find { |(_d, _o, _h, _l, c, _src)| c.present? }
        next unless best

        d, open_usd, high_usd, low_usd, close_usd, source = best

        {
          day: d,
          open_usd: open_usd&.to_f,
          high_usd: high_usd&.to_f,
          low_usd: low_usd&.to_f,
          close_usd: close_usd.to_f,
          source: source
        }
      end
    end
  end
end