# frozen_string_literal: true

module Actors
  class ExchangeCoreFlowSummaryQuery
    DEFAULT_DAYS = 7

    def self.call(days: DEFAULT_DAYS)
      new(days: days).call
    end

    def initialize(days:)
      @days = days
    end

    def call
      addresses = Actors::ExchangeFlowCoreAddressesQuery.call.pluck(:address)

      days.map do |day|
        inflow =
          ExchangeObservedUtxo
            .where(seen_day: day, address: addresses)
            .sum(:value_btc)

        outflow =
          ExchangeObservedUtxo
            .where(spent_day: day, address: addresses)
            .sum(:value_btc)

        {
          day: day,
          inflow_btc: inflow,
          outflow_btc: outflow,
          netflow_btc: inflow - outflow
        }
      end
    end

    private

    def days
      @days.times.map { |i| Date.current - i.days }
    end
  end
end
