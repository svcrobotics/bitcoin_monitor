# frozen_string_literal: true

module Actors
  class ExchangeClusterIdsQuery
    def self.call(min_confidence: 70)
      Actors::ExchangeLikeQuery
        .call(min_confidence: min_confidence)
        .pluck(:cluster_id)
    end
  end
end
