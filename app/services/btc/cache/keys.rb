# frozen_string_literal: true

module Btc
  module Cache
    module Keys
      module_function

      def summary(market: "btcusd")
        "btc:summary:#{market}"
      end

      def daily_history(range:)
        "btc:daily_history:#{range}"
      end

      def candles(market:, timeframe:, limit:)
        "btc:candles:#{market}:#{timeframe}:#{limit}"
      end

      def candles_status(market:, timeframe:)
        "btc:status:#{market}:#{timeframe}"
      end
    end
  end
end