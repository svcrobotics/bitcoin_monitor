# frozen_string_literal: true

module Actors
  class ServiceLikeQuery
    def self.call(min_confidence: 70)
      ActorLabel
        .where(label: "service_like")
        .where("confidence >= ?", min_confidence)
        .order(confidence: :desc, updated_at: :desc)
    end
  end
end
