# frozen_string_literal: true

module Actors
  class ExchangeAddressesQuery
    def self.call(min_confidence: 70)
      cluster_ids = Actors::ExchangeClusterIdsQuery.call(
        min_confidence: min_confidence
      )

      Address
        .where(cluster_id: cluster_ids)
        .where.not(address: [nil, ""])
        .distinct
    end
  end
end
