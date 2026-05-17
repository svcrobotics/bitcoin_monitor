# frozen_string_literal: true

module System
  class ActorLabelsStatus
    INTERESTING_LABELS = %w[
      exchange_like
      whale_like
      service_like
    ].freeze

    def self.call
      labels = ActorLabel.where(label: INTERESTING_LABELS)

      {
        total: labels.count,

        exchange_like: labels.where(label: "exchange_like").count,
        whale_like: labels.where(label: "whale_like").count,
        service_like: labels.where(label: "service_like").count,

        last_updated_at: labels.maximum(:updated_at)
      }
    end
  end
end
