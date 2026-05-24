# frozen_string_literal: true

module Actors
  class ExchangeLikeQuery
    def self.call(min_confidence: 100, source: "actor_metric")
      ActorLabel
        .where(label: "exchange_like", source: source)
        .where("confidence >= ?", min_confidence)
        .order(confidence: :desc, updated_at: :desc)
    end
  end
end