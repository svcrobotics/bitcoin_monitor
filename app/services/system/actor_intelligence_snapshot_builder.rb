# frozen_string_literal: true

module System
  class ActorIntelligenceSnapshotBuilder
    LABELS = %w[
      exchange_like
      whale_like
      etf_like
    ].freeze

    LIMIT = 10

    def self.call
      new.call
    end

    def call
      {
        counts: counts,
        top_candidates: top_candidates
      }
    end

    private

    def counts
      ActorLabel.where(label: LABELS).group(:label).count
    end

    def top_candidates
      ActorLabel
        .where(label: LABELS)
        .order(Arel.sql("(metadata->>'net_btc')::numeric DESC NULLS LAST"))
        .limit(LIMIT)
        .map do |label|
          {
            cluster_id: label.cluster_id,
            label: label.label,
            confidence: label.confidence,
            received_btc: label.metadata["received_btc"],
            sent_btc: label.metadata["sent_btc"],
            net_btc: label.metadata["net_btc"],
            tx_count: label.metadata["tx_count"],
            updated_at: label.updated_at
          }
        end
    end
  end
end
