# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class Btc::DashboardControllerTest < ActionDispatch::IntegrationTest
  test "shows btc dashboard with default params" do
    history = [
      { day: Date.current - 2, close_usd: 82_000.0, source: "composite" },
      { day: Date.current - 1, close_usd: 83_500.0, source: "composite" }
    ]

    summary = {
      day: Date.current - 1,
      close_usd: 83_500.0,
      source: "composite",
      price_now_usd: 83_500.0,
      daily_change_pct: 1.83,
      ma200_usd: 64_000.0,
      ath_usd: 109_000.0,
      drawdown_pct: -23.39,
      amplitude_30d_pct: 11.2,
      price_vs_ma200_pct: 30.47,
      market_bias: "bull",
      cycle_zone: "mid",
      risk_level: "medium",
      updated_at: Time.current
    }

    period_metrics = {
      perf_pct: 1.83,
      high: 83_500.0,
      low: 82_000.0,
      pos_pct: 100,
      max_drawdown_pct: 0.0,
      vol_pct: 1.2,
      vol_label: "Faible"
    }

    summary_ui = {
      price_now_label: "$83500.00",
      daily_change_label: "1.83%",
      ma200_label: "$64000.00",
      ath_label: "$109000.00",
      drawdown_label: "-23.39%",
      amplitude_30d_label: "11.20%",
      price_vs_ma200_label: "30.47%",
      market_bias_label: "Bull",
      cycle_zone_label: "Mid",
      risk_level_label: "Medium",
      source_label: "composite",
      updated_at_label: Time.current.to_s
    }

    chart_data = [
      { x: (Date.current - 2).strftime("%Y-%m-%d"), y: 82_000.0 },
      { x: (Date.current - 1).strftime("%Y-%m-%d"), y: 83_500.0 }
    ]

    candles_data = [
      {
        time: Time.current.to_i,
        open: 83_000.0,
        high: 83_800.0,
        low: 82_900.0,
        close: 83_500.0,
        volume: 12.5
      }
    ]

    candles_status = {
      market: "btcusd",
      timeframe: "1h",
      last_open_time: Time.current - 1.hour,
      last_close_time: Time.current,
      source: "binance",
      candles_count: 120
    }

    freshness_ui = {
      label: "Fresh",
      badge_class: "bg-green-500/15 text-green-300 border border-green-500/30"
    }

    snapshot = MarketSnapshot.new(
      computed_at: Time.current,
      price_now_usd: 83_500.0,
      ma200_usd: 64_000.0,
      ath_usd: 109_000.0,
      drawdown_pct: -23.39,
      amplitude_30d_pct: 11.2,
      market_bias: "bull",
      cycle_zone: "mid",
      risk_level: "medium",
      status: "ok"
    )

    Btc::DailyHistoryQuery.stub(:call, history) do
      Btc::SummaryQuery.stub(:call, summary) do
        Btc::PeriodMetricsQuery.stub(:call, period_metrics) do
          Btc::SummaryPresenter.stub(:call, summary_ui) do
            Btc::ChartPresenter.stub(:call, chart_data) do
              Btc::CandlesQuery.stub(:call, candles_data) do
                Btc::CandlesStatusQuery.stub(:call, candles_status) do
                  Btc::Health::FreshnessChecker.stub(:call, "fresh") do
                    Btc::Health::CandlesFreshnessChecker.stub(:call, "fresh") do
                      Btc::StatusPresenter.stub(:call, freshness_ui) do
                        MarketSnapshot.stub(:latest_ok, snapshot) do
                          get btc_dashboard_path

                          assert_response :success
                          assert_select "h1", text: /BTC Dashboard/i
                          assert_select "p", text: /Lecture daily propre du marché Bitcoin/i
                          assert_select "p", text: /Vue chandeliers/i
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  test "accepts explicit range market and timeframe params" do
    Btc::DailyHistoryQuery.stub(:call, []) do
      Btc::SummaryQuery.stub(:call, {
        day: nil,
        close_usd: nil,
        source: nil,
        price_now_usd: nil,
        daily_change_pct: nil,
        ma200_usd: nil,
        ath_usd: nil,
        drawdown_pct: nil,
        amplitude_30d_pct: nil,
        price_vs_ma200_pct: nil,
        market_bias: nil,
        cycle_zone: nil,
        risk_level: nil,
        updated_at: nil
      }) do
        Btc::PeriodMetricsQuery.stub(:call, {
          perf_pct: nil,
          high: nil,
          low: nil,
          pos_pct: nil,
          max_drawdown_pct: nil,
          vol_pct: nil,
          vol_label: nil
        }) do
          Btc::SummaryPresenter.stub(:call, {
            price_now_label: "—",
            daily_change_label: "—",
            ma200_label: "—",
            ath_label: "—",
            drawdown_label: "—",
            amplitude_30d_label: "—",
            price_vs_ma200_label: "—",
            market_bias_label: "—",
            cycle_zone_label: "—",
            risk_level_label: "—",
            source_label: "—",
            updated_at_label: "—"
          }) do
            Btc::ChartPresenter.stub(:call, []) do
              Btc::CandlesQuery.stub(:call, []) do
                Btc::CandlesStatusQuery.stub(:call, {
                  market: "btceur",
                  timeframe: "5m",
                  last_open_time: nil,
                  last_close_time: nil,
                  source: nil,
                  candles_count: 0
                }) do
                  Btc::Health::FreshnessChecker.stub(:call, "offline") do
                    Btc::Health::CandlesFreshnessChecker.stub(:call, "offline") do
                      offline_ui = {
                        label: "Offline",
                        badge_class: "bg-gray-500/15 text-gray-300 border border-gray-500/30"
                      }

                      Btc::StatusPresenter.stub(:call, offline_ui) do
                        MarketSnapshot.stub(:latest_ok, nil) do
                          get btc_dashboard_path(
                            range: "7d",
                            candles_market: "btceur",
                            candles_timeframe: "5m"
                          )

                          assert_response :success
                          assert_select "a", text: "7d"
                          assert_select "a", text: "BTC/EUR"
                          assert_select "a", text: "5m"
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end