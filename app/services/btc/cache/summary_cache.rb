# frozen_string_literal: true

module Btc
  module Cache
    class SummaryCache
      class << self
        def refresh(market: "btcusd")
          payload = Btc::SummaryQuery.new(market: market).send(:build_summary)

          Btc::Cache::Store.write_json(
            Btc::Cache::Keys.summary(market: market),
            payload,
            expires_in: 5.minutes
          )

          payload
        end
      end
    end
  end
end