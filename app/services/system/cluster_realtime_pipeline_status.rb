# frozen_string_literal: true

module System
  class ClusterRealtimePipelineStatus
    STREAM_KEY = "bitcoin:blocks"
    PENDING_KEY = "cluster:pending_blocks"
    WRITE_STREAM_KEY = "cluster:writes"

    def self.call
      new.call
    end

    def call
      job = JobRun.where(name: "clusters_realtime_pipeline")
                  .order(started_at: :desc)
                  .first

      best_height = BitcoinRpc.new(wallet: nil).getblockcount.to_i
      cursor = ScannerCursor.find_by(name: "cluster_scan")
      cursor_height = cursor&.last_blockheight.to_i
      lag = cursor_height.positive? ? [best_height - cursor_height, 0].max : best_height

      {
        job: job,
        bitcoin_stream_size: redis.xlen(STREAM_KEY),
        pending_blocks: redis.scard(PENDING_KEY),
        write_stream_size: redis.xlen(WRITE_STREAM_KEY),
        last_pipeline_event: ClusterPipelineEvent.order(created_at: :desc).first,

        best_height: best_height,
        cluster_cursor_height: cursor_height,
        cluster_lag: lag,
        cluster_cursor_updated_at: cursor&.updated_at
      }
    end

    private

    def redis
      @redis ||= Redis.new(
        url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
      )
    end
  end
end