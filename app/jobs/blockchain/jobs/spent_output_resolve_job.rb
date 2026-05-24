# frozen_string_literal: true

module Blockchain
  module Jobs
    class SpentOutputResolveJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 3

      BATCH_SIZE = ENV.fetch("SPENT_RESOLVE_BATCH_SIZE", "25").to_i

      def perform(block_height)
        started_at = monotonic_ms

        Rails.logger.info(
          "[spent_output_resolve_job] start height=#{block_height} batch_size=#{BATCH_SIZE}"
        )

        block_buffer = BlockBufferModel.find_by!(height: block_height)
        block = BitcoinRpc.new.getblock(block_buffer.block_hash, 2)

        txs = block.fetch("tx")
        total_batches = (txs.size.to_f / BATCH_SIZE).ceil
        total_spent_rows = 0

        txs.each_slice(BATCH_SIZE).with_index do |tx_batch, index|
          batch_started_at = monotonic_ms

          Rails.logger.info(
            "[spent_output_resolve_job] resolving height=#{block_height} batch=#{index + 1}/#{total_batches} txs=#{tx_batch.size}"
          )

          prevout_cache = Blockchain::Processing::BulkPrevoutResolver.new(
            batch_size: BATCH_SIZE
          ).call(tx_batch)

          partial_block = block.merge("tx" => tx_batch)

          batch = Blockchain::Processing::BlockUtxoBatchBuilder.new(
            prevout_cache: prevout_cache
          ).call(partial_block, block_buffer)

          spent_rows = batch[:spent_rows]

          if spent_rows.any?
            Blockchain::Buffers::SpentOutputBuffer.new.push_many(spent_rows)
          end

          total_spent_rows += spent_rows.size
          batch_duration_ms = monotonic_ms - batch_started_at

          Rails.logger.info(
            "[spent_output_resolve_job] progress " \
            "height=#{block_height} " \
            "batch=#{index + 1}/#{total_batches} " \
            "cache=#{prevout_cache.size} " \
            "spent_rows=#{spent_rows.size} " \
            "total_spent=#{total_spent_rows} " \
            "duration_ms=#{batch_duration_ms}"
          )
        end

        flush = Blockchain::Flushers::SpentOutputFlusher.new.call

        Rails.logger.info(
          "[spent_output_resolve_job] final_flush height=#{block_height} flushed=#{flush[:flushed].to_i}"
        )

        flow_result = Actors::DetectExchangeCoreFlowsForBlock.call(
          block_height: block_height
        )

        duration_ms = monotonic_ms - started_at

        Rails.logger.info(
          "[spent_output_resolve_job] done " \
          "height=#{block_height} " \
          "batches=#{total_batches} " \
          "spent_rows=#{total_spent_rows} " \
          "flushed=#{flush[:flushed].to_i} " \
          "flow_created=#{flow_result[:created].to_i} " \
          "flow_skipped=#{flow_result[:skipped].to_i} " \
          "duration_ms=#{duration_ms}"
        )

        {
          ok: true,
          block_height: block_height,
          batches: total_batches,
          spent_rows: total_spent_rows,
          flushed: flush[:flushed].to_i,
          flow_created: flow_result[:created].to_i,
          flow_skipped: flow_result[:skipped].to_i,
          duration_ms: duration_ms
        }
      end

      private

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end