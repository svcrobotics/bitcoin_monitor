# frozen_string_literal: true

module Blockchain
  module Processing
    class BlockProcessor
      def initialize(
        rpc: BitcoinRpc.new,
        logger: Rails.logger,
        tx_processor: TxProcessor.new,
        flush_after_block: true,
        fast_layer1: ENV.fetch("LAYER1_FAST_PATH", "true") == "true"
      )
        @rpc = rpc
        @logger = logger
        @tx_processor = tx_processor
        @flush_after_block = flush_after_block
        @fast_layer1 = fast_layer1
      end

      def call(block_buffer)
        raise ArgumentError, "block_buffer missing" unless block_buffer

        started_at = monotonic_ms
        rpc_duration_ms = nil
        parse_duration_ms = nil
        flush_duration_ms = nil

        return skipped(block_buffer, reason: "not processable") unless mark_processing(block_buffer)

        rpc_started_at = monotonic_ms
        block = fetch_block(block_buffer.block_hash)
        rpc_duration_ms = monotonic_ms - rpc_started_at

        heartbeat(
          block_buffer,
          metrics: {
            rpc_duration_ms: rpc_duration_ms
          }
        )

        prevout_cache_started_at = monotonic_ms
        prevout_cache = Blockchain::Processing::BulkPrevoutResolver.new.call(block["tx"])
        prevout_cache_duration_ms = monotonic_ms - prevout_cache_started_at

        @logger.info(
          "[block_processor] prevout_cache height=#{block_buffer.height} " \
          "size=#{prevout_cache.size} duration_ms=#{prevout_cache_duration_ms}"
        )

        utxo_result = write_block_utxos(block, block_buffer, prevout_cache)

        parse_started_at = monotonic_ms

        stats =
          if @fast_layer1
            {
              txs: block.fetch("tx").size,
              errors: 0,
              mode: "fast_layer1",
              outputs: utxo_result[:outputs],
              spent_outputs: utxo_result[:spent_outputs]
            }
          else
            @tx_processor = TxProcessor.new(prevout_cache: prevout_cache, write_utxos: false)

            process_transactions(
              block,
              block_buffer,
              parse_started_at: parse_started_at
            )
          end

        parse_duration_ms = monotonic_ms - parse_started_at

        heartbeat(
          block_buffer,
          metrics: {
            parse_duration_ms: parse_duration_ms
          }
        )

        if @flush_after_block
          flush_started_at = monotonic_ms
          flush_buffers
          flush_duration_ms = monotonic_ms - flush_started_at
        end

        duration_ms = monotonic_ms - started_at

        mark_processed(
          block_buffer,
          metrics: {
            duration_ms: duration_ms,
            rpc_duration_ms: rpc_duration_ms,
            parse_duration_ms: parse_duration_ms,
            flush_duration_ms: flush_duration_ms
          }
        )

        @logger.info(
          "[block_processor] done height=#{block_buffer.height} " \
          "mode=#{stats[:mode] || 'full'} " \
          "txs=#{stats[:txs]} errors=#{stats[:errors]} " \
          "duration_ms=#{duration_ms} rpc_ms=#{rpc_duration_ms} " \
          "parse_ms=#{parse_duration_ms} flush_ms=#{flush_duration_ms}"
        )

        {
          ok: true,
          height: block_buffer.height,
          block_hash: block_buffer.block_hash,
          mode: stats[:mode] || "full",
          txs: stats[:txs],
          errors: stats[:errors],
          outputs: stats[:outputs],
          spent_outputs: stats[:spent_outputs],
          duration_ms: duration_ms,
          rpc_duration_ms: rpc_duration_ms,
          parse_duration_ms: parse_duration_ms,
          flush_duration_ms: flush_duration_ms
        }
      rescue StandardError => e
        duration_ms = monotonic_ms - started_at

        mark_failed(
          block_buffer,
          error: e,
          metrics: {
            duration_ms: duration_ms,
            rpc_duration_ms: rpc_duration_ms,
            parse_duration_ms: parse_duration_ms,
            flush_duration_ms: flush_duration_ms
          }
        ) if block_buffer

        @logger.error(
          "[block_processor] error height=#{block_buffer&.height} " \
          "duration_ms=#{duration_ms} #{e.class}: #{e.message}"
        )

        raise
      end

      private

      def write_block_utxos(block, block_buffer, prevout_cache)
        started_at = monotonic_ms

        batch =
          Blockchain::Processing::BlockUtxoBatchBuilder
            .new(prevout_cache: prevout_cache)
            .call(block, block_buffer)

        outputs_count = Blockchain::Buffers::OutputBuffer.new.push_many(batch[:output_rows])
        spent_count = Blockchain::Buffers::SpentOutputBuffer.new.push_many(batch[:spent_rows])

        duration_ms = monotonic_ms - started_at

        @logger.info(
          "[block_processor] block_utxos height=#{block_buffer.height} " \
          "txs=#{batch[:tx_count]} inputs=#{batch[:input_count]} outputs=#{outputs_count} " \
          "spent=#{spent_count} duration_ms=#{duration_ms}"
        )

        {
          outputs: outputs_count,
          spent_outputs: spent_count,
          duration_ms: duration_ms
        }
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end

      def fetch_block(block_hash)
        @rpc.getblock(block_hash, 2)
      end

      def process_transactions(block, block_buffer, parse_started_at:)
        stats = Hash.new(0)

        block.fetch("tx").each_with_index do |tx, index|
          if (index % 50).zero?
            heartbeat(
              block_buffer,
              metrics: {
                parse_duration_ms: monotonic_ms - parse_started_at
              }
            )

            @logger.info(
              "[block_processor] parsing height=#{block_buffer.height} " \
              "tx_index=#{index} txid=#{tx['txid']}"
            )
          end

          @tx_processor.call(
            tx,
            block_height: block_buffer.height,
            block_hash: block_buffer.block_hash,
            block_time: block["time"],
            tx_index: index
          )

          stats[:txs] += 1
        rescue StandardError => e
          stats[:errors] += 1

          @logger.error(
            "[block_processor] tx_error height=#{block_buffer.height} " \
            "txid=#{tx['txid']} #{e.class}: #{e.message}"
          )

          raise
        end

        stats
      end

      def flush_buffers
        Blockchain::Flushers::OutputFlusher.new.call
        Blockchain::Flushers::SpentOutputFlusher.new.call
      end

      def mark_processing(block_buffer)
        Blockchain::Buffer::BlockBuffer.mark_processing(block_buffer.height)
      end

      def mark_processed(block_buffer, metrics: {})
        Blockchain::Buffer::BlockBuffer.mark_processed(block_buffer.height, metrics: metrics)
      end

      def mark_failed(block_buffer, error: nil, metrics: {})
        Blockchain::Buffer::BlockBuffer.mark_failed(block_buffer.height, error: error, metrics: metrics)
      end

      def skipped(block_buffer, reason:)
        @logger.info(
          "[block_processor] skipped height=#{block_buffer.height} " \
          "status=#{block_buffer.status} reason=#{reason}"
        )

        {
          ok: true,
          skipped: true,
          reason: reason,
          height: block_buffer.height,
          status: block_buffer.status
        }
      end

      def heartbeat(block_buffer, metrics: {})
        Blockchain::Buffer::BlockBuffer.heartbeat(block_buffer.height, metrics: metrics)
      end
    end
  end
end