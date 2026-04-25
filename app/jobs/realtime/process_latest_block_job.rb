# frozen_string_literal: true

module Realtime
  class ProcessLatestBlockJob < ApplicationJob
    queue_as :default

    CURSOR_NAME = "realtime_block_stream"

    def perform
      lock = ScannerCursor.find_or_create_by!(name: "realtime_processing_lock")

      locked = lock.with_lock do
        lock.updated_at < 2.minutes.ago
      end

      unless locked
        Rails.logger.info("[realtime] skip_processing_lock_active")
        return { ok: true, skipped: true, reason: "lock_active" }
      end

      lock.touch

      process_latest_block
    end

    private

    def process_latest_block
      rpc = BitcoinRpc.new(wallet: nil)
      height = rpc.getblockcount.to_i
      blockhash = rpc.getblockhash(height)

      cursor = ScannerCursor.find_or_create_by!(name: CURSOR_NAME)

      if cursor.last_blockheight.to_i >= height && cursor.last_blockhash == blockhash
        Rails.logger.info("[realtime] skip_already_processed height=#{height} hash=#{blockhash}")
        return { ok: true, skipped: true, height: height }
      end

      result = ClusterScanner.call(
        from_height: height,
        to_height: height,
        rpc: rpc,
        refresh: false
      )

      if result[:dirty_cluster_ids].present?
        Clusters::RefreshDirtyClustersJob.perform_later(result[:dirty_cluster_ids])
      end

      cursor.update!(
        last_blockheight: height,
        last_blockhash: blockhash
      )

      Rails.logger.info(
        "[realtime] latest_block_processed " \
        "height=#{height} " \
        "dirty_clusters_count=#{result[:dirty_clusters_count]} " \
        "result=#{result.inspect}"
      )

      result
    end
  end
end