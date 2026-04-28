# frozen_string_literal: true

module Clusters
  class BatchFlusher
    PENDING_KEY = ENV.fetch("CLUSTER_PENDING_BLOCKS_KEY", "cluster:pending_blocks")
    MAX_BLOCKS = ENV.fetch("CLUSTER_MAX_BLOCKS_PER_BATCH", "10").to_i

    def self.call(redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
      new(redis: redis).call
    end

    def initialize(redis:)
      @redis = redis
    end

    def call
      heights = @redis.smembers(PENDING_KEY).map(&:to_i).sort.first(MAX_BLOCKS)
      return { processed: 0, heights: [] } if heights.empty?

      cursor_height = last_scanned_height

      valid_heights = heights.select do |height|
        block_exists?(height) && height > cursor_height
      end

      if valid_heights.empty?
        Rails.logger.info(
          "[clusters.batch_flusher] skip already scanned " \
          "cursor=#{cursor_height} heights=#{heights.inspect}"
        )
        heights.each { |height| @redis.srem(PENDING_KEY, height) }
        return {
          processed: 0,
          heights: [],
          skipped: heights,
          reason: "already_scanned_or_invalid",
          cursor_height: cursor_height
        }
      end

      result = Clusters::Processor.call(heights: valid_heights)

      valid_heights.each { |height| @redis.srem(PENDING_KEY, height) }

      {
        processed: valid_heights.size,
        heights: valid_heights,
        result: result
      }
    end

    def last_scanned_height
      ScannerCursor.find_by(name: "cluster_scan")&.last_blockheight.to_i
    end

    private

    def block_exists?(height)
      BitcoinRpc.new.getblockhash(height)
      true
    rescue => e
      Rails.logger.warn("[clusters.batch_flusher] invalid height=#{height} error=#{e.class}: #{e.message}")
      false
    end
  end
end
