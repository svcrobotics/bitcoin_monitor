# frozen_string_literal: true

module Actors
  class ExchangeScoreQuery
    def self.call(cluster_id:)
      metrics = Actors::ClusterMetricsQuery.call(cluster_id: cluster_id)

      score = 0
      score += 25 if metrics[:address_count].to_i >= 1_000
      score += 25 if metrics[:total_tx_count].to_i >= 10_000
      score += 25 if metrics[:activity_span_blocks].to_i >= 1_000
      score += 25 if metrics[:total_sent_sats].to_i >= 10_000_000_000

      metrics.merge(
        exchange_score: score,
        exchange_like: score >= 75
      )
    end
  end
end
