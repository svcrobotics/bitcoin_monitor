# frozen_string_literal: true

module Actors
  class LabeledQuery
    def self.call(label:, min_confidence: 70, limit: nil)
      scope =
        ActorLabel
          .where(label: label)
          .where("confidence >= ?", min_confidence)
          .order(confidence: :desc, updated_at: :desc)

      limit.present? ? scope.limit(limit) : scope
    end
  end
end
