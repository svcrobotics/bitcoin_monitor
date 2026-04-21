# frozen_string_literal: true

module ExchangeLike
  class SummaryQuery
    def call
      {
        addresses_total: ExchangeAddress.count,
        addresses_operational: ExchangeAddress.operational.count,
        addresses_scannable: ExchangeAddress.scannable.count,
        observed_total: ExchangeObservedUtxo.count,
        new_addresses_24h: ExchangeAddress.where("first_seen_at >= ?", 24.hours.ago).count,
        seen_24h: ExchangeObservedUtxo.where("seen_day >= ?", Date.current - 1).count,
        spent_24h: ExchangeObservedUtxo
                     .where.not(spent_day: nil)
                     .where("spent_day >= ?", Date.current - 1)
                     .count
      }
    end
  end
end
