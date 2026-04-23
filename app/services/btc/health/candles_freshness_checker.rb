# app/services/btc/health/candles_freshness_checker.rb
# frozen_string_literal: true

module Btc
  module Health
    class CandlesFreshnessChecker
      THRESHOLDS = {
        "1m" => { fresh: 3.minutes, delayed: 10.minutes },
        "5m" => { fresh: 10.minutes, delayed: 20.minutes },
        "15m" => { fresh: 25.minutes, delayed: 45.minutes },
        "1h" => { fresh: 2.hours, delayed: 4.hours },
        "4h" => { fresh: 6.hours, delayed: 12.hours },
        "1d" => { fresh: 36.hours, delayed: 72.hours }
      }.freeze

      class << self
        def call(last_close_time:, timeframe:)
          new(last_close_time:, timeframe:).call
        end
      end

      def initialize(last_close_time:, timeframe:)
        @last_close_time = last_close_time
        @timeframe = timeframe
      end

      def call
        return "offline" if @last_close_time.blank?

        thresholds = THRESHOLDS.fetch(@timeframe) { THRESHOLDS["1h"] }
        age = Time.current - @last_close_time.to_time

        return "fresh" if age <= thresholds[:fresh]
        return "delayed" if age <= thresholds[:delayed]

        "stale"
      end
    end
  end
end