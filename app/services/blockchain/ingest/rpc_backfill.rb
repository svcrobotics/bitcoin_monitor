# frozen_string_literal: true

module Blockchain
  module Ingest
    class RpcBackfill
      DEFAULT_SLEEP = ENV.fetch("BLOCKCHAIN_BACKFILL_SLEEP", "0.01").to_f

      def initialize(rpc: default_rpc, logger: Rails.logger, sleep_interval: DEFAULT_SLEEP)
        @rpc = rpc
        @logger = logger
        @sleep_interval = sleep_interval
        @stats = Hash.new(0)
      end

      def call(from_height:, to_height:)
        from_height = Integer(from_height)
        to_height = Integer(to_height)

        if from_height > to_height
          return result(ok: false, error: "invalid range from_height=#{from_height} to_height=#{to_height}")
        end

        @logger.info("[backfill] start from=#{from_height} to=#{to_height}")

        (from_height..to_height).each do |height|
          process_height(height)
          sleep(@sleep_interval) if @sleep_interval.positive?
        end

        @logger.info("[backfill] done #{stats_log}")

        result(ok: true)
      end

      private

      attr_reader :stats

      def process_height(height)
        stats[:seen] += 1

        block_hash = @rpc.getblockhash(height)

        if already_buffered?(block_hash)
          stats[:skipped] += 1
          @logger.debug("[backfill] skip existing height=#{height} block_hash=#{block_hash}")
          return
        end

        enqueue_ingestion(block_hash)

        stats[:enqueued] += 1
        @logger.info("[backfill] enqueued height=#{height} block_hash=#{block_hash}")
      rescue StandardError => e
        stats[:errors] += 1
        @logger.error("[backfill] error height=#{height} #{e.class}: #{e.message}")
      end

      def already_buffered?(block_hash)
        BlockBufferModel.exists?(block_hash: block_hash)
      end

      def enqueue_ingestion(block_hash)
        Blockchain::Jobs::BlockIngestJob.perform_async(block_hash)
      end

      def stats_log
        "seen=#{stats[:seen]} enqueued=#{stats[:enqueued]} skipped=#{stats[:skipped]} errors=#{stats[:errors]}"
      end

      def result(ok:, error: nil)
        {
          ok: ok,
          seen: stats[:seen],
          enqueued: stats[:enqueued],
          skipped: stats[:skipped],
          errors: stats[:errors],
          error: error
        }.compact
      end

      def default_rpc
        BitcoinRpc.new
      end
    end
  end
end