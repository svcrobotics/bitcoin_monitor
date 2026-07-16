# frozen_string_literal: true

require "timeout"

module Blockchain
  module Processing
    class BlockProcessor
      RPC_TIMEOUT_SECONDS = 30
      PREVOUT_TIMEOUT_SECONDS = 45
      UTXO_TIMEOUT_SECONDS = 60
      PARSE_TIMEOUT_SECONDS = 120
      FLUSH_TIMEOUT_SECONDS = 300

      def initialize(
        rpc: BitcoinRpc.new,
        logger: Rails.logger,
        tx_processor: nil,
        flush_after_block: false,
        fast_layer1: ENV.fetch("LAYER1_FAST_PATH", "true") == "true",
        block_verbosity: Integer(ENV.fetch("LAYER1_BLOCK_VERBOSITY", "2")),
        strict_prevout: false,
        mark_processed: true
      )
        @rpc = rpc
        @logger = logger
        @tx_processor = tx_processor
        @flush_after_block = flush_after_block
        @fast_layer1 = fast_layer1
        @block_verbosity = block_verbosity.to_i
        @strict_prevout = strict_prevout
        @mark_processed = mark_processed
      end

      def call(block_buffer)
        raise ArgumentError, "block_buffer missing" unless block_buffer

        started_at = monotonic_ms
        rpc_duration_ms = nil
        parse_duration_ms = nil
        flush_duration_ms = nil
        current_stage = "start"

        return skipped(block_buffer, reason: "not processable") unless mark_processing(block_buffer)

        current_stage = "rpc_fetch"
        rpc_started_at = monotonic_ms

        block =
          with_timeout(RPC_TIMEOUT_SECONDS, current_stage, block_buffer) do
            fetch_block(block_buffer.block_hash)
          end

        rpc_duration_ms = monotonic_ms - rpc_started_at

        heartbeat(block_buffer, metrics: { rpc_duration_ms: rpc_duration_ms })

        current_stage = "prevout_cache"
        prevout_cache_started_at = monotonic_ms

        prevout_cache =
          if @fast_layer1
            {}
          else
            begin
              with_timeout(PREVOUT_TIMEOUT_SECONDS, current_stage, block_buffer) do
                Blockchain::Processing::BulkPrevoutResolver.new.call(block["tx"])
              end
            rescue Timeout::Error => e
              @logger.error(
                "[block_processor] prevout_cache_timeout_continue " \
                "height=#{block_buffer.height} " \
                "timeout_seconds=#{PREVOUT_TIMEOUT_SECONDS} " \
                "#{e.class}: #{e.message}"
              )

              {}
            end
          end

        prevout_cache_duration_ms = monotonic_ms - prevout_cache_started_at

        @logger.info(
          "[block_processor] prevout_cache height=#{block_buffer.height} " \
          "size=#{prevout_cache.size} duration_ms=#{prevout_cache_duration_ms} " \
          "block_verbosity=#{@block_verbosity} strict_prevout=#{@strict_prevout}"
        )

        heartbeat(
          block_buffer,
          metrics: { parse_duration_ms: prevout_cache_duration_ms }
        )

        current_stage = "utxo_write"
        utxo_started_at = monotonic_ms

        utxo_result =
          with_timeout(UTXO_TIMEOUT_SECONDS, current_stage, block_buffer) do
            write_block_utxos(block, block_buffer, prevout_cache)
          end

        utxo_duration_ms = monotonic_ms - utxo_started_at

        @logger.info(
          "[block_processor] utxo_write height=#{block_buffer.height} " \
          "duration_ms=#{utxo_duration_ms}"
        )

        current_stage = "parse_transactions"
        parse_started_at = monotonic_ms

        stats =
          with_timeout(PARSE_TIMEOUT_SECONDS, current_stage, block_buffer) do
            if @fast_layer1
              {
                txs: block.fetch("tx").size,
                errors: 0,
                mode: "fast_layer1",
                outputs: utxo_result[:outputs],
                spent_outputs: utxo_result[:spent_outputs],
                prevout_found: utxo_result[:prevout_found],
                prevout_missing: utxo_result[:prevout_missing]
              }
            else
              @tx_processor ||= TxProcessor.new(
                prevout_cache: prevout_cache,
                write_utxos: false
              )

              process_transactions(
                block,
                block_buffer,
                parse_started_at: parse_started_at
              )
            end
          end

        parse_duration_ms = monotonic_ms - parse_started_at

        heartbeat(block_buffer, metrics: { parse_duration_ms: parse_duration_ms })

        if @flush_after_block
          current_stage = "flush_buffers"
          flush_started_at = monotonic_ms

          with_timeout(FLUSH_TIMEOUT_SECONDS, current_stage, block_buffer) do
            flush_buffers
          end

          flush_duration_ms = monotonic_ms - flush_started_at
        end

        duration_ms = monotonic_ms - started_at

        if @mark_processed
          mark_processed(
            block_buffer,
            metrics: {
              duration_ms: duration_ms,
              rpc_duration_ms: rpc_duration_ms,
              parse_duration_ms: parse_duration_ms,
              flush_duration_ms: flush_duration_ms
            }
          )
        else
          heartbeat(
            block_buffer,
            metrics: {
              duration_ms: duration_ms,
              rpc_duration_ms: rpc_duration_ms,
              parse_duration_ms: parse_duration_ms,
              flush_duration_ms: flush_duration_ms
            }
          )
        end

        @logger.info(
          "[block_processor] done height=#{block_buffer.height} " \
          "mode=#{stats[:mode] || 'full'} txs=#{stats[:txs]} " \
          "errors=#{stats[:errors]} duration_ms=#{duration_ms} " \
          "rpc_ms=#{rpc_duration_ms} parse_ms=#{parse_duration_ms} " \
          "flush_ms=#{flush_duration_ms} " \
          "block_verbosity=#{@block_verbosity} " \
          "strict_prevout=#{@strict_prevout} " \
          "mark_processed=#{@mark_processed}"
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
          prevout_found: stats[:prevout_found],
          prevout_missing: stats[:prevout_missing],
          duration_ms: duration_ms,
          rpc_duration_ms: rpc_duration_ms,
          parse_duration_ms: parse_duration_ms,
          flush_duration_ms: flush_duration_ms
        }

      rescue Timeout::Error => e
        duration_ms = monotonic_ms - started_at

        fail_block_and_alert(
          block_buffer,
          error: e,
          stage: current_stage,
          duration_ms: duration_ms,
          metrics: {
            duration_ms: duration_ms,
            rpc_duration_ms: rpc_duration_ms,
            parse_duration_ms: parse_duration_ms,
            flush_duration_ms: flush_duration_ms
          }
        )

        {
          ok: false,
          timeout: true,
          height: block_buffer&.height,
          stage: current_stage,
          error: e.class.name,
          message: e.message
        }

      rescue StandardError => e
        duration_ms = monotonic_ms - started_at

        fail_block_and_alert(
          block_buffer,
          error: e,
          stage: current_stage,
          duration_ms: duration_ms,
          metrics: {
            duration_ms: duration_ms,
            rpc_duration_ms: rpc_duration_ms,
            parse_duration_ms: parse_duration_ms,
            flush_duration_ms: flush_duration_ms
          }
        )

        {
          ok: false,
          height: block_buffer&.height,
          stage: current_stage,
          error: e.class.name,
          message: e.message
        }
      end

      private

      def with_timeout(seconds, stage, block_buffer)
        Timeout.timeout(seconds) do
          yield
        end
      rescue Timeout::Error
        @logger.error(
          "[block_processor] timeout height=#{block_buffer&.height} " \
          "stage=#{stage} timeout_seconds=#{seconds}"
        )

        raise
      end

      def fail_block_and_alert(block_buffer, error:, stage:, duration_ms:, metrics: {})
        return unless block_buffer

        mark_failed(block_buffer, error: error, metrics: metrics)

        @logger.error(
          "[layer1_alert] block_failed height=#{block_buffer.height} " \
          "stage=#{stage} duration_ms=#{duration_ms} " \
          "#{error.class}: #{error.message}"
        )

        create_system_event(
          block_buffer,
          error: error,
          stage: stage,
          duration_ms: duration_ms
        )
      end

      def create_system_event(block_buffer, error:, stage:, duration_ms:)
        return unless defined?(SystemEvent)

        SystemEvent.create!(
          level: "critical",
          source: "layer1",
          event_type: error.is_a?(Timeout::Error) ? "block_processing_timeout" : "block_processing_error",
          title: "Layer 1 block failed",
          message: "Block #{block_buffer.height} failed at stage #{stage}. Layer 1 continued.",
          metadata: {
            height: block_buffer.height,
            block_hash: block_buffer.block_hash,
            stage: stage,
            duration_ms: duration_ms,
            error_class: error.class.name,
            error_message: error.message
          }
        )
      rescue StandardError => event_error
        @logger.error(
          "[layer1_alert] system_event_failed height=#{block_buffer.height} " \
          "#{event_error.class}: #{event_error.message}"
        )
      end

      def write_block_utxos(block, block_buffer, prevout_cache)
        started_at = monotonic_ms

        batch =
          Blockchain::Processing::BlockUtxoBatchBuilder
            .new(
              prevout_cache: prevout_cache,
              strict_prevout: @strict_prevout
            )
            .call(block, block_buffer)

        outputs_count =
          Blockchain::Buffers::OutputBuffer.new.push_many(batch[:output_rows])

        spent_count =
          Blockchain::Buffers::SpentOutputBuffer.new.push_many(batch[:spent_rows])

        duration_ms = monotonic_ms - started_at

        @logger.info(
          "[block_processor] block_utxos height=#{block_buffer.height} " \
          "txs=#{batch[:tx_count]} inputs=#{batch[:input_count]} " \
          "outputs=#{outputs_count} spent=#{spent_count} " \
          "prevout_found=#{batch[:prevout_found_count]} " \
          "prevout_missing=#{batch[:prevout_missing_count]} " \
          "duration_ms=#{duration_ms}"
        )

        {
          outputs: outputs_count,
          spent_outputs: spent_count,
          prevout_found: batch[:prevout_found_count],
          prevout_missing: batch[:prevout_missing_count],
          duration_ms: duration_ms
        }
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end

      def fetch_block(block_hash)
        @rpc.getblock(block_hash, @block_verbosity)
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
        10.times do
          out = Blockchain::Flushers::OutputFlusher.new.call
          spent =
            Blockchain::Flushers::SpentOutputFlusherSelector.call(
              mode: :recovery
            )

          break if out[:flushed].to_i.zero? && spent[:flushed].to_i.zero?
        end
      end

      def mark_processing(block_buffer)
        Blockchain::Buffer::BlockBuffer.mark_processing(block_buffer.height)
      end

      def mark_processed(block_buffer, metrics: {})
        Blockchain::Buffer::BlockBuffer.mark_processed(
          block_buffer.height,
          metrics: metrics
        )
      end

      def mark_failed(block_buffer, error: nil, metrics: {})
        Blockchain::Buffer::BlockBuffer.mark_failed(
          block_buffer.height,
          error: error,
          metrics: metrics
        )
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
        Blockchain::Buffer::BlockBuffer.heartbeat(
          block_buffer.height,
          metrics: metrics
        )
      end
    end
  end
end
