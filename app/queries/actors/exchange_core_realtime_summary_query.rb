# frozen_string_literal: true

module Actors
  class ExchangeCoreRealtimeSummaryQuery
    def self.call(since: 1.hour.ago)
      events = ExchangeCoreFlowEvent.where("event_time >= ?", since)

      inflow = events.where(direction: "inflow").sum(:amount_btc)
      outflow = events.where(direction: "outflow").sum(:amount_btc)

      {
        since: since,
        inflow_btc: inflow,
        outflow_btc: outflow,
        netflow_btc: inflow - outflow,
        events_count: events.count,
        last_event_at: events.maximum(:event_time)
      }
    end
  end
end
