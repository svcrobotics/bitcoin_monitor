# frozen_string_literal: true

require "sidekiq/api"

module System
  class ClusterPipelineStatus
    BATCH_CURSOR_NAME = "cluster_scan"
    REALTIME_CURSOR_NAME = "realtime_block_stream"

    def self.call
      new.call
    end

    def call
      batch_cursor = ScannerCursor.find_by(name: BATCH_CURSOR_NAME)
      realtime_cursor = ScannerCursor.find_by(name: REALTIME_CURSOR_NAME)

      best = BlockBufferModel.where(status: "processed").maximum(:height).to_i

      queue = Sidekiq::Queue.new

      refresh_jobs =
        queue.count do |job|
          wrapped = job.item.dig("wrapped")
          klass = job.item["class"]

          [
            "Clusters::RefreshDirtyClustersJob"
          ].include?(wrapped) || [
            "Clusters::RefreshDirtyClustersJob"
          ].include?(klass)
        end

      batch_lag = lag_for(best, batch_cursor)
      realtime_lag = lag_for(best, realtime_cursor)
      dirty_queue_size = Clusters::DirtyClusterQueue.size

      {
        # Legacy / compatibility fields used by current view
        scanner_height: realtime_cursor&.last_blockheight,
        best_height: best,
        lag: realtime_lag,

        # New explicit fields
        batch: {
          cursor_name: BATCH_CURSOR_NAME,
          scanner_height: batch_cursor&.last_blockheight,
          lag: batch_lag,
          updated_at: batch_cursor&.updated_at,
          last_blockhash: batch_cursor&.last_blockhash,
          status: compute_lag_status(batch_lag)
        },

        realtime: {
          cursor_name: REALTIME_CURSOR_NAME,
          scanner_height: realtime_cursor&.last_blockheight,
          lag: realtime_lag,
          updated_at: realtime_cursor&.updated_at,
          last_blockhash: realtime_cursor&.last_blockhash,
          status: compute_lag_status(realtime_lag)
        },

        refresh_queue: refresh_jobs,

        profiles_count: 0,
        metrics_count: 0,
        signals_count: 0,
        legacy_disabled: true,

        last_profile_update: nil,
        legacy_cluster_profiles_disabled: true,
        last_metric_day: nil,
        last_signal_day: nil,

        dirty_queue_size: dirty_queue_size,

        status: compute_status(
          batch_lag: batch_lag,
          realtime_lag: realtime_lag,
          refresh_jobs: refresh_jobs,
          dirty_queue_size: dirty_queue_size
        )
      }
    rescue => e
      {
        status: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def lag_for(best, cursor)
      return nil if best.to_i <= 0
      return nil if cursor&.last_blockheight.blank?

      best.to_i - cursor.last_blockheight.to_i
    end

    def compute_lag_status(lag)
      return "unknown" if lag.nil?
      return "critical" if lag > 24
      return "warning" if lag > 6

      "ok"
    end

    def compute_status(batch_lag:, realtime_lag:, refresh_jobs:, dirty_queue_size:)
      return "critical" if realtime_lag.to_i > 24
      return "warning" if batch_lag.to_i > 72
      return "warning" if dirty_queue_size.to_i > 5_000
      return "warning" if refresh_jobs > 100

      "ok"
    end
  end
end