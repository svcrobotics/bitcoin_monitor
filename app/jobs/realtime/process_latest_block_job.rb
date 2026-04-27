# frozen_string_literal: true

module Realtime
  class ProcessLatestBlockJob < ApplicationJob
    queue_as :realtime

    CURSOR_NAME = "realtime_block_stream"
    LOCK_KEY    = "lock:realtime_processor"
    LOCK_TTL    = 15.minutes.to_i

    MAX_BLOCKS_PER_RUN = Integer(ENV.fetch("REALTIME_MAX_BLOCKS_PER_RUN", "5"))

    def perform
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

      locked = redis.set(
        LOCK_KEY,
        "#{Process.pid}:#{Time.current.to_i}",
        nx: true,
        ex: LOCK_TTL
      )

      unless locked
        Rails.logger.info("[realtime] skip already_running redis_lock=#{LOCK_KEY}")
        return { ok: true, skipped: true, reason: "lock_active" }
      end

      process_pending_blocks
    ensure
      redis&.del(LOCK_KEY)
    end

    private

    def process_pending_blocks
      rpc = BitcoinRpc.new(wallet: nil)
      best_height = rpc.getblockcount.to_i

      cursor = ScannerCursor.find_or_create_by!(name: CURSOR_NAME)

      start_height =
        if cursor.last_blockheight.to_i.positive?
          cursor.last_blockheight.to_i + 1
        else
          best_height
        end

      if start_height > best_height
        Rails.logger.info("[realtime] skip_already_caught_up height=#{best_height}")
        return { ok: true, skipped: true, reason: "caught_up", height: best_height }
      end

      end_height = [best_height, start_height + MAX_BLOCKS_PER_RUN - 1].min
      end_hash = rpc.getblockhash(end_height)

      result = ClusterScanner.call(
        from_height: start_height,
        to_height: end_height,
        rpc: rpc,
        refresh: false
      )

      if result[:dirty_cluster_ids].present?
        Clusters::RefreshDirtyClustersJob.perform_later(result[:dirty_cluster_ids])
      end

      cursor.update!(
        last_blockheight: end_height,
        last_blockhash: end_hash
      )

      Rails.logger.info(
        "[realtime] blocks_processed " \
        "from=#{start_height} to=#{end_height} best=#{best_height} " \
        "dirty_clusters_count=#{result[:dirty_clusters_count]}"
      )

      self.class.perform_later if end_height < best_height

      result.merge(
        realtime_from: start_height,
        realtime_to: end_height,
        best_height: best_height,
        more_pending: end_height < best_height
      )
    end
  end
end