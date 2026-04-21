# frozen_string_literal: true

module ExchangeLike
  class DailySeriesQuery
    def initialize(days: 30)
      @days = days.to_i
    end

    def call
      {
        builder_daily_discovery: fill_daily_series(builder_raw_counts),
        scanner_seen_daily: fill_daily_series(scanner_seen_raw_counts),
        scanner_spent_daily: fill_daily_series(scanner_spent_raw_counts)
      }
    end

    private

    def builder_raw_counts
      ExchangeAddress
        .where("first_seen_at >= ?", @days.days.ago)
        .group("DATE(first_seen_at)")
        .order("DATE(first_seen_at)")
        .count
    end

    def scanner_seen_raw_counts
      ExchangeObservedUtxo
        .where("seen_day >= ?", @days.days.ago.to_date)
        .group("seen_day")
        .order("seen_day")
        .count
    end

    def scanner_spent_raw_counts
      ExchangeObservedUtxo
        .where.not(spent_day: nil)
        .where("spent_day >= ?", @days.days.ago.to_date)
        .group("spent_day")
        .order("spent_day")
        .count
    end

    def fill_daily_series(raw_counts)
      start_date = @days.days.ago.to_date
      end_date   = Date.current

      (start_date..end_date).each_with_object({}) do |day, series|
        series[day] = raw_counts[day] || raw_counts[day.to_s] || 0
      end
    end
  end
end
