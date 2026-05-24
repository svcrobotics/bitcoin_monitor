# frozen_string_literal: true

module Actors
  class ExchangeActiveAddressesQuery
    def self.call(min_confidence: 70, min_tx_count: 2)
      cluster_ids = Actors::ExchangeClusterIdsQuery.call(
        min_confidence: min_confidence
      )

      Address
        .where(cluster_id: cluster_ids)
        .where.not(address: [nil, ""])
        .where("tx_count >= ?", min_tx_count)
        .distinct
    end
  end
end
