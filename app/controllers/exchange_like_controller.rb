class ExchangeLikeController < ApplicationController
  def index
    summary = ExchangeLike::SummaryQuery.new.call
    series  = ExchangeLike::DailySeriesQuery.new(days: 30).call

    @addresses_total       = summary[:addresses_total]
    @addresses_operational = summary[:addresses_operational]
    @addresses_scannable   = summary[:addresses_scannable]
    @observed_total        = summary[:observed_total]
    @new_addresses_24h     = summary[:new_addresses_24h]
    @seen_24h              = summary[:seen_24h]
    @spent_24h             = summary[:spent_24h]

    @builder_daily_discovery = series[:builder_daily_discovery]
    @scanner_seen_daily      = series[:scanner_seen_daily]
    @scanner_spent_daily     = series[:scanner_spent_daily]

    @top_addresses = ExchangeLike::TopAddressesQuery.new(limit: 10).call

    @best_height = BitcoinRpc.new.getblockcount.to_i

    builder_cursor = ScannerCursor.find_by(name: "exchange_address_builder")
    scanner_cursor = ScannerCursor.find_by(name: "exchange_observed_scan")

    @builder_status = build_engine_status(builder_cursor, @best_height)
    @scanner_status = build_engine_status(scanner_cursor, @best_height)

    @builder_status_presenter = ExchangeLike::StatusPresenter.new(@builder_status)
    @scanner_status_presenter = ExchangeLike::StatusPresenter.new(@scanner_status)
  end

  private

  def build_engine_status(cursor, best_height)
    cursor_height = cursor&.last_blockheight
    updated_at    = cursor&.updated_at
    lag           = cursor_height ? (best_height - cursor_height) : nil

    {
      cursor_height: cursor_height,
      updated_at: updated_at,
      lag: lag,
      health: engine_health(lag: lag, updated_at: updated_at)
    }
  end

  def engine_health(lag:, updated_at:)
    return "unknown" if lag.nil? || updated_at.nil?
    return "stale" if updated_at < 12.hours.ago
    return "late" if lag > 24

    "ok"
  end
end