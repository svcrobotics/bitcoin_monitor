# frozen_string_literal: true

module Actors
  class SummaryQuery
    LABELS = %w[
      exchange_like
      whale_like
      service_like
      retail_like
      unknown
    ].freeze

    def self.call
      counts = ActorLabel.group(:label).count

      {
        total: ActorLabel.count,
        labels: LABELS.index_with { |label| counts[label] || 0 },
        interesting_total:
          (counts["exchange_like"] || 0) +
          (counts["whale_like"] || 0) +
          (counts["service_like"] || 0)
      }
    end
  end
end
