# frozen_string_literal: true

module System
  class ActorLabelsStatus
    def self.call
      {
        total: ActorLabel.count,
        displayed: 100,

        exchange_like: ActorLabel.where(label: "exchange_like").count,
        whale_like: ActorLabel.where(label: "whale_like").count,
        service_like: ActorLabel.where(label: "service_like").count,
        retail_like: ActorLabel.where(label: "retail_like").count,
        unknown: ActorLabel.where(label: "unknown").count,

        last_updated_at: ActorLabel.maximum(:updated_at)
      }
    end
  end
end