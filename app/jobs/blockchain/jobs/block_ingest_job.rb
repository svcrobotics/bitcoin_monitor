# frozen_string_literal: true

module Blockchain
  module Jobs
    class BlockIngestJob
      include Sidekiq::Job

      sidekiq_options queue: :ingest, retry: 5

      def perform(block_hash)
        Rails.logger.info("[block_ingest_job] start block_hash=#{block_hash}")

        Blockchain::Ingest::BlockIngestService.new.call(block_hash)

        Rails.logger.info("[block_ingest_job] done block_hash=#{block_hash}")
      rescue StandardError => e
        Rails.logger.error(
          "[block_ingest_job] error block_hash=#{block_hash} #{e.class}: #{e.message}"
        )
        raise
      end
    end
  end
end