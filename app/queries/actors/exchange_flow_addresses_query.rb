# frozen_string_literal: true

module Actors
  class ExchangeFlowAddressesQuery
    DEFAULT_MIN_CONFIDENCE = 100
    DEFAULT_MIN_TX_COUNT = 25

    def self.call(
      min_confidence: DEFAULT_MIN_CONFIDENCE,
      min_tx_count: DEFAULT_MIN_TX_COUNT
    )
      Actors::ExchangeActiveAddressesQuery.call(
        min_confidence: min_confidence,
        min_tx_count: min_tx_count
      )
    end
  end
end
