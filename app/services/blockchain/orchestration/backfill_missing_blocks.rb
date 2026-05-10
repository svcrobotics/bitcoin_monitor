# frozen_string_literal: true

module Blockchain
  module Orchestration
    class BackfillMissingBlocks
      DEFAULT_LIMIT = ENV.fetch("LAYER1_BACKFILL_LIMIT", 25).to_i

      def initialize(rpc: BitcoinRpc.new, logger: Rails.logger, ingest_service: nil)
        @rpc = rpc
        @logger = logger
        @ingest_service = ingest_service || Blockchain::Ingest::BlockIngestService.new(rpc: @rpc)
      end

      def call(limit: DEFAULT_LIMIT)
        started_at = Time.current

        best_height = @rpc.getblockcount.to_i
        last_ingested_height = current_last_ingested_height

        from_height = last_ingested_height + 1
        to_height = [best_height, from_height + limit.to_i - 1].min

        if from_height > to_height
          return result(
            ok: true,
            note: "nothing to ingest",
            best_height: best_height,
            last_ingested_height: last_ingested_height,
            from_height: from_height,
            to_height: to_height,
            ingested_count: 0,
            started_at: started_at
          )
        end

        ingested_count = 0
        errors = []

        (from_height..to_height).each do |height|
          block_hash = @rpc.getblockhash(height)
          @ingest_service.call(block_hash)

          ingested_count += 1
          @logger.info("[layer1_backfill] ingested height=#{height} hash=#{block_hash}")
        rescue StandardError => e
          errors << {
            height: height,
            error_class: e.class.name,
            message: e.message
          }

          @logger.error("[layer1_backfill] error height=#{height} #{e.class}: #{e.message}")
        end

        result(
          ok: errors.empty?,
          best_height: best_height,
          last_ingested_height: last_ingested_height,
          from_height: from_height,
          to_height: to_height,
          ingested_count: ingested_count,
          errors: errors,
          started_at: started_at
        )
      end

      private

      def current_last_ingested_height
        ActiveRecord::Base.connection
          .exec_query("SELECT COALESCE(MAX(height), 0) AS height FROM block_buffers")
          .first["height"]
          .to_i
      end

      def result(**attrs)
        finished_at = Time.current

        attrs.merge(
          finished_at: finished_at,
          duration_ms: ((finished_at - attrs[:started_at]) * 1000).round
        )
      end
    end
  end
end