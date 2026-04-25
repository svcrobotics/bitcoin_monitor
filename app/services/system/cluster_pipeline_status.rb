# frozen_string_literal: true

require "sidekiq/api"

module System
  class ClusterPipelineStatus
    def self.call
      new.call
    end

    def call
      cursor = ScannerCursor.find_by(name: "realtime_block_stream")
      best = BitcoinRpc.new.getblockcount.to_i

      queue = Sidekiq::Queue.new

      refresh_jobs =
        queue.count do |job|
          wrapped = job.item.dig("wrapped")

          [
            "ClusterRefreshDispatchJob",
            "ClusterRefreshJob"
          ].include?(wrapped)
        end

      {
        scanner_height: cursor&.last_blockheight,
        best_height: best,
        lag: cursor&.last_blockheight ? (best - cursor.last_blockheight) : nil,

        refresh_queue: refresh_jobs,

        profiles_count: ClusterProfile.count,
        metrics_count: ClusterMetric.count,
        signals_count: ClusterSignal.count,

        last_profile_update: ClusterProfile.maximum(:updated_at),
        last_metric_day: ClusterMetric.maximum(:snapshot_date),
        last_signal_day: ClusterSignal.maximum(:snapshot_date),

        status: compute_status(
          lag: cursor&.last_blockheight ? (best - cursor.last_blockheight) : nil,
          refresh_jobs: refresh_jobs
        )
      }
    rescue => e
      {
        status: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def compute_status(lag:, refresh_jobs:)
      return "critical" if lag.to_i > 24
      return "warning" if refresh_jobs > 100

      "ok"
    end
  end
end