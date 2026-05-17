# frozen_string_literal: true

module Actors
  class WhaleLikeQuery
    def self.call(min_confidence: 70)
      ActorLabel
        .where(label: "whale_like")
        .where("confidence >= ?", min_confidence)
        .order(confidence: :desc, updated_at: :desc)
    end
  end
end
