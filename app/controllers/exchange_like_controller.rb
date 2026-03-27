class ExchangeLikeController < ApplicationController
  def index
    @addresses_total       = ExchangeAddress.count
    @addresses_operational = ExchangeAddress.operational.count
    @addresses_scannable   = ExchangeAddress.scannable.count

    @observed_total = ExchangeObservedUtxo.count

    @top_addresses =
      ExchangeAddress
        .operational
        .order(occurrences: :desc)
        .limit(10)

    builder_raw =
      ExchangeAddress
        .where("first_seen_at >= ?", 30.days.ago)
        .group("DATE(first_seen_at)")
        .order("DATE(first_seen_at)")
        .count

    @builder_daily_discovery = fill_daily_series(builder_raw, days: 30)

    seen_raw =
      ExchangeObservedUtxo
        .where("seen_day >= ?", 30.days.ago.to_date)
        .group("seen_day")
        .order("seen_day")
        .count

    @scanner_seen_daily = fill_daily_series(seen_raw, days: 30)

    spent_raw =
      ExchangeObservedUtxo
        .where.not(spent_day: nil)
        .where("spent_day >= ?", 30.days.ago.to_date)
        .group("spent_day")
        .order("spent_day")
        .count

    @scanner_spent_daily = fill_daily_series(spent_raw, days: 30)

    @best_height = BitcoinRpc.new.getblockcount.to_i

    builder_cursor = ScannerCursor.find_by(name: "exchange_address_builder")
    scanner_cursor = ScannerCursor.find_by(name: "exchange_observed_scan")

    @builder_status = {
      cursor_height: builder_cursor&.last_blockheight,
      updated_at: builder_cursor&.updated_at,
      lag: builder_cursor&.last_blockheight ? (@best_height - builder_cursor.last_blockheight) : nil
    }

    @scanner_status = {
      cursor_height: scanner_cursor&.last_blockheight,
      updated_at: scanner_cursor&.updated_at,
      lag: scanner_cursor&.last_blockheight ? (@best_height - scanner_cursor.last_blockheight) : nil
    }
  end

  private

  def fill_daily_series(raw_counts, days: 30)
    start_date = days.days.ago.to_date
    end_date   = Date.current

    (start_date..end_date).each_with_object({}) do |day, series|
      series[day] = raw_counts[day] || raw_counts[day.to_s] || 0
    end
  end
end