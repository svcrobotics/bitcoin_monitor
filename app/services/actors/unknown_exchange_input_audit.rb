# frozen_string_literal: true

module Actors
  class UnknownExchangeInputAudit
    SOURCE = "actor_profile_exchange_like"

    def self.call(height: nil, limit: 20)
      new(height: height, limit: limit).call
    end

    def initialize(height: nil, limit: 20)
      @height = height || ClusterInput.maximum(:spent_block_height)
      @limit = limit.to_i
    end

    def call
      scope = ClusterInput.where(spent_block_height: @height)

      known = scope
        .joins("INNER JOIN exchange_core_addresses ON exchange_core_addresses.address = cluster_inputs.address")
        .where(exchange_core_addresses: { source: SOURCE })

      unknown = scope
        .joins("LEFT JOIN exchange_core_addresses ON exchange_core_addresses.address = cluster_inputs.address AND exchange_core_addresses.source = '#{SOURCE}'")
        .where(exchange_core_addresses: { id: nil })

      {
        height: @height,
        total_inputs: scope.count,
        total_btc: scope.sum(:amount_btc).to_f,
        known_exchange_inputs: known.count,
        known_exchange_btc: known.sum(:amount_btc).to_f,
        unknown_inputs: unknown.count,
        unknown_btc: unknown.sum(:amount_btc).to_f,
        top_unknown_addresses: unknown
          .group(:address)
          .order(Arel.sql("SUM(cluster_inputs.amount_btc) DESC"))
          .limit(@limit)
          .sum(:amount_btc)
      }
    end
  end
end
