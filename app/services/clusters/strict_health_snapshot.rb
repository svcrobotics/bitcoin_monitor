# frozen_string_literal: true

module Clusters
  class StrictHealthSnapshot
    STALE_AFTER = Clusters::ActorProfileHandoffDispatcher::STALE_AFTER

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      layer1_tip = BlockBufferModel.where(status: "processed").maximum(:height)
      cluster_tip = ClusterProcessedBlock.where(status: "processed").maximum(:height)
      last_processed_at = ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:processed_at)
      counts = ClusterActorProfileHandoff.group(:status).count
      oldest = ClusterActorProfileHandoff
        .where(status: %w[pending failed])
        .minimum(:created_at)
      stale_claims = ClusterActorProfileHandoff
        .where(status: "processing")
        .where("claimed_at < ?", @now - STALE_AFTER)
        .count

      {
        status: health_status(layer1_tip: layer1_tip, cluster_tip: cluster_tip,
          failed: counts.fetch("failed", 0), stale_claims: stale_claims),
        database_available: true,
        layer1_tip: layer1_tip,
        cluster_tip: cluster_tip,
        cluster_lag: exact_lag(layer1_tip, cluster_tip),
        last_cluster_processed_at: last_processed_at,
        handoffs: {
          pending: counts.fetch("pending", 0),
          processing: counts.fetch("processing", 0),
          failed: counts.fetch("failed", 0),
          completed: counts.fetch("completed", 0),
          stale_claims: stale_claims,
          oldest_pending_age_seconds: oldest ? [@now - oldest, 0].max.to_i : nil
        }
      }
    rescue ActiveRecord::ActiveRecordError => error
      {
        status: "unavailable",
        database_available: false,
        error_class: error.class.name,
        layer1_tip: nil,
        cluster_tip: nil,
        cluster_lag: nil,
        last_cluster_processed_at: nil,
        handoffs: {
          pending: nil,
          processing: nil,
          failed: nil,
          completed: nil,
          stale_claims: nil,
          oldest_pending_age_seconds: nil
        }
      }
    end

    private

    def exact_lag(layer1_tip, cluster_tip)
      return nil if layer1_tip.nil? || cluster_tip.nil?

      [layer1_tip - cluster_tip, 0].max
    end

    def health_status(layer1_tip:, cluster_tip:, failed:, stale_claims:)
      return "unknown" if layer1_tip.nil? || cluster_tip.nil?
      return "critical" if failed.positive? || stale_claims.positive?
      return "warning" if layer1_tip > cluster_tip

      "healthy"
    end
  end
end
