# frozen_string_literal: true

module Blockchain
  module Jobs
    class SpentOutputResolveJob
      include Sidekiq::Job

      sidekiq_options queue: :spent_resolve, retry: 3

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

          batch = Blockchain::Processing::SpentRowsBuilder.new(
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

        Layer1::OrchestratorJob.perform_later

        flush = { flushed: 0 }

        Rails.logger.info(
          "[spent_output_resolve_job] drain_enqueued height=#{block_height}"
        )

        if ENV.fetch("ENABLE_EXCHANGE_AFTER_SPENT_RESOLVE", "0") == "1"
          Actors::ExchangeCoreFlowsForBlockJob.perform_async(block_height)

          Rails.logger.info(
            "[spent_output_resolve_job] exchange_core_flows_enqueued height=#{block_height}"
          )
        else
          Rails.logger.info(
            "[spent_output_resolve_job] exchange_core_flows_skipped height=#{block_height}"
          )
        end

        duration_ms = monotonic_ms - started_at

        Rails.logger.info(
          "[spent_output_resolve_job] done " \
          "height=#{block_height} " \
          "batches=#{total_batches} " \
          "spent_rows=#{total_spent_rows} " \
          "flushed=#{flush[:flushed].to_i} " \
          "duration_ms=#{duration_ms}"
        )

        refresh_health_snapshots(block_height)
        {
          ok: true,
          block_height: block_height,
          batches: total_batches,
          spent_rows: total_spent_rows,
          flushed: flush[:flushed].to_i,
          duration_ms: duration_ms
        }
      end

      private

      def refresh_health_snapshots(block_height)
        Layer1::Realtime::CachedHealthSnapshot.refresh!
        Clusters::CachedHealthSnapshot.refresh!

        Rails.logger.info(
          "[spent_output_resolve_job] health_snapshots_refreshed height=#{block_height}"
        )
      rescue StandardError => e
        Rails.logger.warn(
          "[spent_output_resolve_job] health_snapshot_refresh_failed " \
          "height=#{block_height} #{e.class}: #{e.message}"
        )
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end
