# frozen_string_literal: true

module Layer1
  class StrictWindowRebuilder
    class BlockHashChanged < StandardError; end
    class MarkProcessedFailed < StandardError; end

    OUTPUTS_KEY = Blockchain::Buffers::OutputBuffer::KEY
    SPENT_KEY = "blockchain:spent_outputs:buffer"

    def self.call(from_height:, to_height:, **options)
      new(from_height: from_height, to_height: to_height, **options).call
    end

    def initialize(
      from_height:,
      to_height:,
      rpc: BitcoinRpc.new,
      logger: Rails.logger,
      block_verbosity: 3,
      strict_prevout: true
    )
      @from_height = from_height.to_i
      @to_height = to_height.to_i
      @rpc = rpc
      @logger = logger
      @block_verbosity = block_verbosity.to_i
      @strict_prevout = strict_prevout
      @redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
    end

    def call
      validate_range!

      started_at = monotonic_ms
      processed = 0
      failed = nil
      results = []

      @logger.info(
        "[layer1_strict_rebuild] start from=#{@from_height} to=#{@to_height} " \
        "block_verbosity=#{@block_verbosity} strict_prevout=#{@strict_prevout}"
      )

      (@from_height..@to_height).each do |height|
        result = process_height(height)
        results << result

        if result[:ok]
          processed += 1
        else
          failed = result
          break
        end
      end

      duration_ms = monotonic_ms - started_at

      response = {
        ok: failed.nil?,
        from_height: @from_height,
        to_height: @to_height,
        processed: processed,
        failed: failed,
        duration_ms: duration_ms,
        results: results.last(10)
      }

      @logger.info("[layer1_strict_rebuild] done #{response.inspect}")
      response
    end

    private

    def validate_range!
      raise ArgumentError, "from_height must be positive" if @from_height <= 0
      raise ArgumentError, "to_height must be positive" if @to_height <= 0
      raise ArgumentError, "from_height > to_height" if @from_height > @to_height
    end

    def process_height(height)
      started_at = monotonic_ms

      @logger.info("[layer1_strict_rebuild] block_start height=#{height}")

      stage_timings = {}

      block_hash =
        measure_stage(stage_timings, height, "rpc_getblockhash") do
          @rpc.getblockhash(height)
        end

      header =
        measure_stage(stage_timings, height, "rpc_getblock_header") do
          @rpc.getblock(block_hash, 1)
        end

      block_buffer =
        measure_stage(stage_timings, height, "prepare_block_buffer") do
          prepare_block_buffer!(
            height: height,
            block_hash: block_hash,
            header: header
          )
        end

      processor_result =
        measure_stage(stage_timings, height, "block_processor") do
          Blockchain::Processing::BlockProcessor.new(
            rpc: @rpc,
            block_verbosity: @block_verbosity,
            strict_prevout: @strict_prevout,
            flush_after_block: false,
            mark_processed: false
          ).call(block_buffer)
        end

      unless processor_result[:ok]
        mark_failed!(
          block_buffer,
          "processor_failed",
          processor_result.inspect
        )

        return {
          ok: false,
          height: height,
          stage: "processor",
          processor_result: processor_result
        }
      end

      measure_stage(stage_timings, height, "flush_buffers_until_empty") do
        flush_buffers_until_empty!(height: height)
      end

      reconcile_result =
        measure_stage(stage_timings, height, "reconcile_strict_utxo_state") do
          Layer1::ReconcileStrictUtxoState.call(height: height)
        end

      @logger.info(
        "[layer1_strict_rebuild] reconcile_strict_utxo_state #{reconcile_result.inspect}"
      )

      outputs_audit =
        measure_stage(stage_timings, height, "audit_outputs") do
          Layer1::AuditBlock.call(height: height)
        end

      unless outputs_audit.status == "healthy"
        mark_failed!(
          block_buffer,
          "audit_outputs_failed",
          outputs_audit.issues.inspect
        )

        return {
          ok: false,
          height: height,
          stage: "audit_outputs",
          audit_status: outputs_audit.status,
          issues: outputs_audit.issues
        }
      end

      inputs_audit =
        measure_stage(stage_timings, height, "audit_inputs") do
          Layer1::AuditBlockInputs.call(height: height)
        end

      unless inputs_audit[:ok]
        mark_failed!(
          block_buffer,
          "audit_inputs_failed",
          inputs_audit[:issues].inspect
        )

        return {
          ok: false,
          height: height,
          stage: "audit_inputs",
          audit_status: "failed",
          issues: inputs_audit[:issues]
        }
      end

      utxo_audit =
        measure_stage(stage_timings, height, "audit_utxo_state") do
          Layer1::AuditBlockUtxoState.call(height: height)
        end

      unless utxo_audit[:ok]
        mark_failed!(
          block_buffer,
          "audit_utxo_state_failed",
          utxo_audit[:issues].inspect
        )

        return {
          ok: false,
          height: height,
          stage: "audit_utxo_state",
          audit_status: "failed",
          issues: utxo_audit[:issues]
        }
      end

      strict_output_facts =
        measure_stage(stage_timings, height, "strict_output_facts") do
          Layer1::StrictOutputFacts.call(height: height)
        end

      tx_output_projection =
        measure_stage(stage_timings, height, "register_tx_output_projection") do
          Layer1::TxOutputProjection::Register.call(
            height: height,
            block_hash: block_hash,
            expected_outputs_count: strict_output_facts.fetch(:outputs_count),
            expected_outputs_value_btc: strict_output_facts.fetch(:outputs_value_btc)
          )
        end

      duration_ms = monotonic_ms - started_at

      counts =
        measure_stage(stage_timings, height, "final_counts") do
          {
            strict_outputs_count: strict_output_facts.fetch(:outputs_count),
            cluster_inputs_count: ClusterInput.where(spent_block_height: height).count
          }
        end

      strict_outputs_count = counts[:strict_outputs_count]
      cluster_inputs_count = counts[:cluster_inputs_count]

      final_metrics =
        {
          strict_rebuild: true,
          audit_run_id: outputs_audit.id,
          outputs_audit_ok: true,
          inputs_audit_ok: true,
          utxo_audit_ok: true,
          duration_ms: duration_ms,
          rpc_duration_ms: processor_result[:rpc_duration_ms],
          parse_duration_ms: processor_result[:parse_duration_ms],
          flush_duration_ms: stage_timings[:flush_buffers_until_empty],
          block_verbosity: @block_verbosity,
          strict_prevout: @strict_prevout,
          strict_outputs: strict_outputs_count,
          cluster_inputs: cluster_inputs_count,
          stage_timings: stage_timings,
          node_inputs_count: inputs_audit[:node_inputs_count],
          db_inputs_count: inputs_audit[:db_inputs_count],
          expected_live_outputs_count: utxo_audit[:expected_live_outputs_count],
          actual_live_utxos_count: utxo_audit[:actual_live_utxos_count],
          tx_output_projection_deferred: true,
          tx_output_projection_status: tx_output_projection.status,
          tx_outputs_sync_deferred: true
        }

      tx_outputs_sync =
        finalize_block!(
          height: height,
          block_hash: block_hash,
          final_metrics: final_metrics
        )

      result = {
        ok: true,
        height: height,
        block_hash: block_hash,

        outputs_audit_status: outputs_audit.status,

        inputs_audit_ok: true,
        node_inputs_count: inputs_audit[:node_inputs_count],
        db_inputs_count: inputs_audit[:db_inputs_count],
        node_inputs_value_btc: inputs_audit[:node_inputs_value_btc],
        db_inputs_value_btc: inputs_audit[:db_inputs_value_btc],

        utxo_audit_ok: true,
        reconcile_spent_outputs: reconcile_result,
        tx_output_projection_deferred: true,
        tx_output_projection_status: tx_output_projection.status,
        tx_outputs_sync_deferred: tx_outputs_sync.present?,
        tx_outputs_sync_status: tx_outputs_sync&.status,
        expected_live_outputs_count: utxo_audit[:expected_live_outputs_count],
        actual_live_utxos_count: utxo_audit[:actual_live_utxos_count],
        expected_live_value_btc: utxo_audit[:expected_live_value_btc],
        actual_live_value_btc: utxo_audit[:actual_live_value_btc],
        spent_rows_still_in_utxo: utxo_audit[:spent_rows_still_in_utxo],
        orphan_utxos_count: utxo_audit[:orphan_utxos_count],
        spent_utxos_count: utxo_audit[:spent_utxos_count],

        tx_count: block_buffer.tx_count,
        strict_outputs: strict_outputs_count,
        cluster_inputs: cluster_inputs_count,
        duration_ms: duration_ms,
        stage_timings: stage_timings
      }

      @logger.info("[layer1_strict_rebuild] block_done #{result.inspect}")

      result
    rescue StandardError => e
      begin
        buffer = BlockBufferModel.find_by(height: height)
        mark_failed!(buffer, e.class.name, e.message) if buffer
      rescue StandardError
        nil
      end

      {
        ok: false,
        height: height,
        stage: "exception",
        error_class: e.class.name,
        error_message: e.message
      }
    end

    def measure_stage(timings, height, stage)
      started_at = monotonic_ms

      result = yield

      duration_ms = monotonic_ms - started_at
      timings[stage.to_sym] = duration_ms

      Blockchain::Buffer::BlockBuffer.heartbeat(height) if height.is_a?(Integer)

      @logger.info(
        "[layer1_strict_rebuild] stage_done " \
        "height=#{height} stage=#{stage} duration_ms=#{duration_ms}"
      )

      result
    rescue StandardError => e
      duration_ms = monotonic_ms - started_at
      timings[stage.to_sym] = duration_ms

      @logger.error(
        "[layer1_strict_rebuild] stage_failed " \
        "height=#{height} stage=#{stage} duration_ms=#{duration_ms} " \
        "error=#{e.class}: #{e.message}"
      )

      raise
    end

    def prepare_block_buffer!(height:, block_hash:, header:)
      previous_hash = header["previousblockhash"]
      tx_count = header["nTx"] || Array(header["tx"]).size
      size_bytes = header["size"]
      block_time = Time.at(header["time"]).in_time_zone

      block_buffer = BlockBufferModel.find_or_initialize_by(height: height)

      block_buffer.assign_attributes(
        block_hash: block_hash,
        previous_hash: previous_hash,
        tx_count: tx_count,
        size_bytes: size_bytes,
        block_time: block_time,
        status: "enqueued",
        processed_at: nil,
        error_class: nil,
        error_message: nil
      )

      block_buffer.save!
      block_buffer
    end

    def flush_buffers_until_empty!(height:)
      flush_started_at = monotonic_ms

      100.times do |iteration|
        iteration_number = iteration + 1

        before_outputs = @redis.llen(OUTPUTS_KEY)
        before_spent = @redis.llen(SPENT_KEY)

        Blockchain::Buffer::BlockBuffer.heartbeat(
          height,
          metrics: {
            phase: "flush_start",
            flush_iteration: iteration_number,
            outputs_remaining: before_outputs,
            spent_remaining: before_spent
          }
        )

        @logger.info(
          "[layer1_strict_rebuild] flush_iteration_start " \
          "height=#{height} " \
          "iteration=#{iteration_number} " \
          "outputs_before=#{before_outputs} " \
          "spent_before=#{before_spent}"
        )

        out =
          measure_stage(
            {},
            height,
            "output_flusher_iteration_#{iteration_number}"
          ) do
            Blockchain::Flushers::OutputFlusher
              .new(redis: @redis)
              .call
          end

        after_outputs = @redis.llen(OUTPUTS_KEY)

        Blockchain::Buffer::BlockBuffer.heartbeat(
          height,
          metrics: {
            phase: "outputs_flushed",
            flush_iteration: iteration_number,
            outputs_flushed: out[:flushed].to_i,
            outputs_remaining: after_outputs
          }
        )

        @logger.info(
          "[layer1_strict_rebuild] output_flusher_done " \
          "height=#{height} " \
          "iteration=#{iteration_number} " \
          "outputs_flushed=#{out[:flushed].to_i} " \
          "outputs_remaining=#{after_outputs}"
        )

        spent =
          measure_stage(
            {},
            height,
            "spent_flusher_iteration_#{iteration_number}"
          ) do
            Blockchain::Flushers::SpentOutputFlusherSelector.call(
              redis: @redis,
              mode: :realtime
            )
          end

        outputs_remaining = @redis.llen(OUTPUTS_KEY)
        spent_remaining = @redis.llen(SPENT_KEY)

        Blockchain::Buffer::BlockBuffer.heartbeat(
          height,
          metrics: {
            phase: "flush_complete",
            flush_iteration: iteration_number,
            flush_duration_ms: monotonic_ms - flush_started_at,
            outputs_remaining: outputs_remaining,
            spent_remaining: spent_remaining
          }
        )

        @logger.info(
          "[layer1_strict_rebuild] spent_flusher_done " \
          "height=#{height} " \
          "iteration=#{iteration_number} " \
          "spent_flushed=#{spent[:flushed].to_i} " \
          "outputs_remaining=#{outputs_remaining} " \
          "spent_remaining=#{spent_remaining}"
        )

        break if outputs_remaining.zero? && spent_remaining.zero?
      end

      outputs_remaining = @redis.llen(OUTPUTS_KEY)
      spent_remaining = @redis.llen(SPENT_KEY)

      return if outputs_remaining.zero? && spent_remaining.zero?

      raise(
        "redis buffers not empty after flush " \
        "outputs=#{outputs_remaining} spent=#{spent_remaining}"
      )
    end

    def finalize_block!(height:, block_hash:, final_metrics:)
      tx_outputs_sync = nil

      ApplicationRecord.transaction do
        block = BlockBufferModel.lock.find_by!(height: height)

        unless block.block_hash == block_hash
          raise BlockHashChanged,
                "block hash changed at height=#{height} " \
                "expected=#{block_hash} actual=#{block.block_hash}"
        end

        tx_outputs_sync =
          Layer1::TxOutputsSpentSync::Register.call(
            height: height,
            block_hash: block_hash
          )

        marked =
          Blockchain::Buffer::BlockBuffer.mark_processed(
            height,
            metrics: final_metrics
          )

        unless marked
          raise MarkProcessedFailed,
                "failed to mark BlockBuffer processed at height=#{height}"
        end
      end

      tx_outputs_sync
    end

    def enqueue_tx_outputs_async_sync
      Layer1::TxOutputsSpentSyncKickJob.perform_async
    rescue StandardError => e
      @logger.error(
        "[layer1_strict_rebuild] tx_outputs_async_enqueue_failed " \
        "error=#{e.class}: #{e.message}"
      )
    end

    def mark_failed!(block_buffer, error_class, error_message)
      Blockchain::Buffer::BlockBuffer.mark_failed(
        block_buffer.height,
        error: StandardError.new("#{error_class}: #{error_message}"),
        metrics: {
          strict_rebuild: true
        }
      )
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
    end
  end
end
