# frozen_string_literal: true

class BtcIntraday5mJob < ApplicationJob
  queue_as :btc_realtime

  def perform
    JobRunner.run!(
      "btc_intraday_5m",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = Btc::Ingestion::IntradayBackfill.call(
        market: "btcusd",
        timeframe: "5m"
      )

      broadcast_btc_dashboard_chart!

      JobRunner.heartbeat!(jr)

      result
    end
  end

  private

  def broadcast_btc_dashboard_chart!
    history = Btc::DailyHistoryQuery.call(range: "7d")
    summary = Btc::SummaryQuery.call
    chart_data = Btc::ChartPresenter.call(history)

    latest_5m_close = BtcCandle
      .for_market("btcusd")
      .for_timeframe("5m")
      .order(open_time: :desc)
      .pick(:close)

    if latest_5m_close.present?
      chart_data << {
        x: Date.current,
        y: latest_5m_close.to_f
      }
    end

    Turbo::StreamsChannel.broadcast_replace_to(
      "btc_dashboard",
      target: "btc-main-chart",
      partial: "btc/dashboard/main_chart",
      locals: {
        range: "7d",
        source_label: summary[:source],
        chart_data: chart_data
      }
    )

    if latest_5m_close.present?
      Turbo::StreamsChannel.broadcast_replace_to(
        "btc_dashboard",
        target: "btc-live-price",
        partial: "btc/dashboard/live_price",
        locals: {
          price: latest_5m_close.to_f
        }
      )
    end
  end
end