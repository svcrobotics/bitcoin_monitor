# frozen_string_literal: true

module Blockchain
  module Jobs
    class BlockProcessJob
      include Sidekiq::Job

      sidekiq_options queue: :process, retry: 5

      def perform(block_height)
        Rails.logger.info("[block_process_job] start height=#{block_height}")

        block = find_block!(block_height)
        result = Blockchain::Processing::BlockProcessor.new.call(block)

        if result[:skipped]
          Rails.logger.info(
            "[block_process_job] skipped height=#{block_height} reason=#{result[:reason]}"
          )
          return
        end

        if result[:ok]
          Blockchain::Jobs::SpentOutputResolveJob.perform_async(block_height)

          Rails.logger.info(
            "[block_process_job] spent_output_resolve_enqueued height=#{block_height}"
          )
        end

        Rails.logger.info(
          "[block_process_job] done height=#{block_height} " \
          "txs=#{result[:txs].to_i} errors=#{result[:errors].to_i}"
        )
      rescue StandardError => e
        Rails.logger.error(
          "[block_process_job] error height=#{block_height} #{e.class}: #{e.message}"
        )
        raise
      end

      private

      def find_block!(height)
        BlockBufferModel.find_by!(height: height)
      end
    end
  end
end