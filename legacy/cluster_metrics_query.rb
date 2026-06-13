# frozen_string_literal: true

module Actors
  class ClusterMetricsQuery
    def self.call(cluster_id:)
      addresses = Address.where(cluster_id: cluster_id)

      first_seen = addresses.minimum(:first_seen_height)
      last_seen = addresses.maximum(:last_seen_height)

      {
        cluster_id: cluster_id,
        address_count: addresses.count,
        total_tx_count: addresses.sum(:tx_count),
        total_received_sats: addresses.sum(:total_received_sats),
        total_sent_sats: addresses.sum(:total_sent_sats),
        first_seen_height: first_seen,
        last_seen_height: last_seen,
        activity_span_blocks: first_seen && last_seen ? last_seen - first_seen : nil
      }
    end
  end
end