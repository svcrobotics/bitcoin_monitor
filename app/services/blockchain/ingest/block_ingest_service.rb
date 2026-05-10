# frozen_string_literal: true

module Blockchain
  module Ingest
    class BlockIngestService
      def initialize(rpc: default_rpc, logger: Rails.logger)
        @rpc = rpc
        @logger = logger
      end

      def call(block_hash)
        block = fetch_block(block_hash)

        upsert_block!(block)
        enqueue_processing(block)

        @logger.info("[block_ingest] buffered height=#{block['height']} block_hash=#{block_hash}")
      rescue StandardError => e
        @logger.error("[block_ingest] error block_hash=#{block_hash} #{e.class}: #{e.message}")
        raise
      end

      private

      def fetch_block(block_hash)
        @rpc.getblock(block_hash, 1)
      end

      def upsert_block!(block)
        now = Time.current

        BlockBufferModel.upsert(
          {
            height: block["height"],
            block_hash: block["hash"],
            previous_hash: block["previousblockhash"],
            tx_count: block["nTx"],
            status: "pending",
            created_at: now,
            updated_at: now
          },
          unique_by: :index_block_buffers_on_block_hash,
          update_only: [:height, :previous_hash, :tx_count]
        )
      end

      def enqueue_processing(block)
        if Blockchain::Buffer::BlockBuffer.mark_enqueued(block["height"])
          Blockchain::Jobs::BlockProcessJob.perform_async(block["height"])
        end
      end

      def default_rpc
        BitcoinRpc.new
      end
    end
  end
end