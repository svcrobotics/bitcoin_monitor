# frozen_string_literal: true

module Clusters
  class StrictTipSyncJob < ApplicationJob
    queue_as :cluster_strict

    DEFAULT_WAIT_SECONDS = 30

    def perform(limit: nil, reschedule: true)
      if layer1_busy_for_cluster?
        Rails.logger.info("[cluster_strict_tip_sync_job] skipped reason=layer1_busy_for_cluster")

        schedule_next(limit: limit) if reschedule

        return {
          ok: true,
          status: "skipped",
          reason: "layer1_busy_for_cluster"
        }
      end

      result = Clusters::StrictTipSyncer.call(
        limit: limit || Integer(ENV.fetch("CLUSTER_STRICT_SYNC_LIMIT", "2"))
      )

      Rails.logger.info("[cluster_strict_tip_sync_job] done result=#{result.inspect}")

      result
    ensure
      schedule_next(limit: limit) if reschedule
    end

    private

    def layer1_busy_for_cluster?
      snapshot = Layer1::HealthSnapshot.call

      lag = snapshot.dig(:sync, :lag) || snapshot[:lag]
      buffers = snapshot[:buffers] || {}

      outputs_buffer = buffers[:outputs].to_i
      spent_buffer = buffers[:spent].to_i

      max_safe_lag = Integer(ENV.fetch("CLUSTER_WAIT_LAYER1_LAG_GT", "2"))

      return true if outputs_buffer.positive?
      return true if spent_buffer.positive?
      return true if lag.to_i > max_safe_lag

      false
    rescue StandardError => e
      Rails.logger.warn("[cluster_strict_tip_sync_job] layer1_busy_check_failed #{e.class}: #{e.message}")
      false
    end

    # Compatibilité avec les anciens jobs encore chargés / anciennes versions du code.
    def layer1_lag_positive?
      layer1_busy_for_cluster?
    end

    def wait_seconds
      Integer(ENV.fetch("CLUSTER_STRICT_WAIT_SECONDS", DEFAULT_WAIT_SECONDS.to_s))
    end

    def schedule_next(limit:)
      self.class
        .set(wait: wait_seconds.seconds)
        .perform_later(
          limit: limit || Integer(ENV.fetch("CLUSTER_STRICT_SYNC_LIMIT", "2")),
          reschedule: true
        )
    end
  end
end
