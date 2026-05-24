# frozen_string_literal: true

module Actors
  class ExchangeCoreFlowDayBuilder
    def self.call(day:)
      new(day: day).call
    end

    def initialize(day:)
      @day = day.to_date
    end

    def call
      addresses = Actors::ExchangeFlowCoreAddressesQuery.call.pluck(:address)

      inflow =
        ExchangeObservedUtxo
          .where(seen_day: @day, address: addresses)
          .sum(:value_btc)

      outflow =
        ExchangeObservedUtxo
          .where(spent_day: @day, address: addresses)
          .sum(:value_btc)

      row = ExchangeCoreFlowDay.find_or_initialize_by(day: @day)

      row.inflow_btc = inflow
      row.outflow_btc = outflow
      row.netflow_btc = inflow - outflow
      row.events_count =
        ExchangeObservedUtxo.where(seen_day: @day, address: addresses).count +
        ExchangeObservedUtxo.where(spent_day: @day, address: addresses).count

      row.source = "actor_graph_core"
      row.save!

      {
        ok: true,
        day: @day,
        inflow_btc: row.inflow_btc,
        outflow_btc: row.outflow_btc,
        netflow_btc: row.netflow_btc,
        events_count: row.events_count
      }
    end
  end
end
