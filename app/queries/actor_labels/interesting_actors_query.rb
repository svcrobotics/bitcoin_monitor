# frozen_string_literal: true

module ActorLabels
  class InterestingActorsQuery
    INTERESTING_LABELS = %w[
      exchange_like
      whale_like
      service_like
    ].freeze

    def self.call(limit: 50)
      ActorLabel
        .where(label: INTERESTING_LABELS)
        .order(confidence: :desc, updated_at: :desc)
        .limit(limit)
    end
  end
end
