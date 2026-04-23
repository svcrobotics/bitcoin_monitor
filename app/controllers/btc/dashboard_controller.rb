# app/controllers/btc/dashboard_controller.rb
# frozen_string_literal: true

module Btc
  class DashboardController < ApplicationController
    def show
      @range = params[:range].presence_in(%w[7d 30d 1y]) || "30d"

      @candles_market =
        params[:candles_market].presence_in(%w[btcusd btceur]) || "btcusd"

      @candles_timeframe =
        params[:candles_timeframe].presence_in(%w[1m 5m 15m 1h 4h 1d]) || "1h"

      @history = Btc::DailyHistoryQuery.call(range: @range)
      @summary = Btc::SummaryQuery.call
      @period_metrics = Btc::PeriodMetricsQuery.call(history: @history)

      @summary_ui = Btc::SummaryPresenter.call(@summary)
      @chart_data = Btc::ChartPresenter.call(@history)

      @candles_data = Btc::CandlesQuery.call(
        market: @candles_market,
        timeframe: @candles_timeframe,
        limit: 120
      )

      @candles_status = Btc::CandlesStatusQuery.call(
        market: @candles_market,
        timeframe: @candles_timeframe
      )

      candles_freshness = Btc::Health::CandlesFreshnessChecker.call(
        last_close_time: @candles_status[:last_close_time],
        timeframe: @candles_timeframe
      )
      @candles_freshness = Btc::StatusPresenter.call(candles_freshness)

      freshness = Btc::Health::FreshnessChecker.call(@summary[:updated_at])
      @freshness = Btc::StatusPresenter.call(freshness)

      @snapshot = MarketSnapshot.latest_ok
    end
  end
end