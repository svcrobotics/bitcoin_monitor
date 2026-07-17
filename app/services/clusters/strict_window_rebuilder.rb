# frozen_string_literal: true

module Clusters
  class StrictWindowRebuilder
    def self.call(
      from_height:,
      to_height:,
      yield_guard: nil,
      max_runtime_seconds: nil,
      slice_started_at_ms: nil
    )
      new(
        from_height: from_height,
        to_height: to_height,
        yield_guard: yield_guard,
        max_runtime_seconds: max_runtime_seconds,
        slice_started_at_ms: slice_started_at_ms
      ).call
    end

    def initialize(
      from_height:,
      to_height:,
      yield_guard: nil,
      max_runtime_seconds: nil,
      slice_started_at_ms: nil,
      logger: Rails.logger
    )
      @from_height = from_height.to_i
      @to_height = to_height.to_i
      @yield_guard = yield_guard
      @max_runtime_seconds = max_runtime_seconds&.to_i
      @slice_started_at_ms = slice_started_at_ms
      @logger = logger
    end

    def call
      started_at = @slice_started_at_ms || monotonic_ms
      results = []
      failed = nil
      yielded = nil
      stop_reason = nil

      @logger.info(
        "[cluster_strict_rebuild] slice_started " \
        "from_height=#{@from_height} to_height=#{@to_height} " \
        "max_runtime_seconds=#{@max_runtime_seconds}"
      )

      (@from_height..@to_height).each do |height|
        if runtime_exceeded?(started_at)
          stop_reason = "runtime_budget_exceeded"
          yielded =
            {
              ok: true,
              status: "yielded_to_layer1",
              reason: stop_reason,
              next_height: height
            }

          @logger.info(
            "[cluster_strict_rebuild] slice_stop_reason=#{stop_reason} " \
            "next_height=#{height}"
          )

          break
        end

        guard =
          cooperative_guard(height)

        unless guard[:allowed]
          stop_reason = guard.dig(:decision, :reason) || "pipeline_controller_denied"
          yielded =
            {
              ok: true,
              status: "yielded_to_layer1",
              reason: stop_reason,
              decision: guard[:decision],
              next_height: height
            }

          @logger.info(
            "[cluster_strict_rebuild] yielded " \
            "height=#{height} decision=#{guard[:decision].inspect}"
          )

          break
        end

        result = process_block(height)
        results << result

        after_block_guard =
          cooperative_guard(height)

        unless result[:ok]
          failed = result
          break
        end

        unless after_block_guard[:allowed]
          stop_reason =
            after_block_guard.dig(:decision, :reason) ||
            "pipeline_controller_denied_after_block"

          yielded =
            {
              ok: true,
              status: "yielded_to_layer1",
              reason: stop_reason,
              decision: after_block_guard[:decision],
              next_height: height + 1
            }

          @logger.info(
            "[cluster_strict_rebuild] yielded_after_block " \
            "height=#{height} decision=#{after_block_guard[:decision].inspect}"
          )

          break
        end
      end

      runtime_ms = monotonic_ms - started_at
      blocks_processed = results.count { |r| r[:ok] }

      @logger.info(
        "[cluster_strict_rebuild] slice_finished " \
        "slice_stop_reason=#{stop_reason || (failed ? 'failed' : 'complete')} " \
        "blocks_processed=#{blocks_processed} " \
        "runtime_ms=#{runtime_ms}"
      )

      {
        ok: failed.nil?,
        status:
          if failed
            "failed"
          elsif yielded
            "yielded_to_layer1"
          else
            "processed"
          end,
        from_height: @from_height,
        to_height: @to_height,
        processed: blocks_processed,
        failed: failed,
        yielded: yielded,
        duration_ms: runtime_ms,
        results: results
      }
    end

    private

    def cooperative_guard(height)
      return { allowed: true } unless @yield_guard.respond_to?(:call)

      decision =
        @yield_guard.call(height)

      {
        allowed: decision.fetch(:allowed, false),
        decision: decision
      }
    rescue StandardError => error
      @logger.warn(
        "[cluster_strict_rebuild] cooperative_guard_failed " \
        "height=#{height} error=#{error.class}: #{error.message}"
      )

      { allowed: true }
    end

    def runtime_exceeded?(started_at)
      return false unless @max_runtime_seconds.to_i.positive?

      monotonic_ms - started_at >= @max_runtime_seconds * 1000
    end

    def process_block(height)
      started_at = monotonic_ms
      processing_started_at = Time.current
      stage_timings = {}
      cleanup_result = skipped_cleanup_result

      @logger.info("[cluster_strict_rebuild] block_start height=#{height}")

      layer1_block = BlockBufferModel.find_by(height: height, status: "processed")

      unless layer1_block
        result =
          failure(
            height: height,
            stage: "layer1_check",
            message: "Layer1 block is not processed"
          )

        persist_failed_checkpoint(
          height: height,
          block_hash: failed_block_hash(height: height),
          processing_started_at: processing_started_at,
          scan_result: {},
          cleanup_result: cleanup_result,
          audit_result: {},
          stage_timings: stage_timings,
          started_at: started_at,
          error_message: result[:message]
        )

        return result
      end

      block_hash = layer1_block.block_hash.to_s
      checkpoint = ClusterProcessedBlock.find_by(height: height)

      if checkpoint&.status == "processed"
        if checkpoint.block_hash == block_hash
          return {
            ok: true,
            height: height,
            block_hash: block_hash,
            skipped: true,
            reason: "already_processed",
            checkpoint_id: checkpoint.id,
            duration_ms: monotonic_ms - started_at
          }
        end

        result =
          failure(
            height: height,
            stage: "checkpoint",
            message: "block_hash_mismatch",
            scan_result: checkpoint.scan_result || {},
            cleanup_result: checkpoint.cleanup_result || {},
            audit_result: checkpoint.audit_result || {}
          ).merge(
            block_hash: block_hash,
            checkpoint_block_hash: checkpoint.block_hash
          )

        persist_failed_checkpoint(
          height: height,
          block_hash: checkpoint.block_hash,
          processing_started_at: processing_started_at,
          scan_result: checkpoint.scan_result || {},
          cleanup_result: checkpoint.cleanup_result || cleanup_result,
          audit_result: checkpoint.audit_result || {},
          stage_timings: stage_timings,
          started_at: started_at,
          error_message: result[:message]
        )

        return result
      end

      mark_processing_checkpoint(
        height: height,
        block_hash: block_hash,
        processing_started_at: processing_started_at,
        stage_timings: stage_timings
      )

      scan_result = {}
      audit_result = {}

      begin
        scan_result =
          measure_stage("scan_ms", stage_timings) do
            ClusterScanner.call(
              from_height: height,
              to_height: height,
              refresh: false,
              mode: :batch
            )
          end

        audit_result =
          measure_stage("audit_ms", stage_timings) do
            Clusters::AuditBlock.call(height: height)
          end
      rescue StandardError => error
        persist_failed_checkpoint(
          height: height,
          block_hash: block_hash,
          processing_started_at: processing_started_at,
          scan_result: scan_result,
          cleanup_result: cleanup_result,
          audit_result: audit_result,
          stage_timings: stage_timings,
          started_at: started_at,
          error_message: "#{error.class}: #{error.message}"
        )

        raise
      end

      unless audit_result[:ok]
        result =
          failure(
            height: height,
            stage: "audit",
            message: "Cluster audit failed",
            scan_result: scan_result,
            cleanup_result: cleanup_result,
            audit_result: audit_result
          )

        persist_failed_checkpoint(
          height: height,
          block_hash: block_hash,
          processing_started_at: processing_started_at,
          scan_result: scan_result,
          cleanup_result: cleanup_result,
          audit_result: audit_result,
          stage_timings: stage_timings,
          started_at: started_at,
          error_message: result[:message]
        )

        return result
      end

      processed_at = Time.current
      duration_ms = monotonic_ms - started_at

      measure_checkpoint(stage_timings) do
        ClusterProcessedBlock.upsert(
          {
            height: height,
            block_hash: block_hash,
            status: "processed",
            scan_result: serializable_hash(scan_result),
            cleanup_result: serializable_hash(cleanup_result),
            audit_result: serializable_hash(audit_result),
            processing_started_at: processing_started_at,
            processed_at: processed_at,
            duration_ms: duration_ms,
            stage_timings: serializable_hash(stage_timings),
            error_message: nil,
            created_at: processing_started_at,
            updated_at: processed_at
          },
          unique_by: :index_cluster_processed_blocks_on_height
        )
      end

      result = {
        ok: true,
        height: height,
        block_hash: block_hash,
        scan_result: scan_result,
        cleanup_result: cleanup_result,
        audit_result: audit_result,
        duration_ms: duration_ms,
        stage_timings: stage_timings
      }

      @logger.info("[cluster_strict_rebuild] block_done #{result.inspect}")

      result
    end

    def mark_processing_checkpoint(height:, block_hash:, processing_started_at:, stage_timings:)
      measure_checkpoint(stage_timings) do
        ClusterProcessedBlock.upsert(
          {
            height: height,
            block_hash: block_hash,
            status: "processing",
            scan_result: {},
            cleanup_result: skipped_cleanup_result,
            audit_result: {},
            processing_started_at: processing_started_at,
            processed_at: nil,
            duration_ms: nil,
            stage_timings: serializable_hash(stage_timings),
            error_message: nil,
            created_at: processing_started_at,
            updated_at: Time.current
          },
          unique_by: :index_cluster_processed_blocks_on_height
        )
      end
    end

    def persist_failed_checkpoint(
      height:,
      block_hash:,
      processing_started_at:,
      scan_result:,
      cleanup_result:,
      audit_result:,
      stage_timings:,
      started_at:,
      error_message:
    )
      duration_ms = monotonic_ms - started_at

      measure_checkpoint(stage_timings) do
        ClusterProcessedBlock.upsert(
          {
            height: height,
            block_hash: block_hash,
            status: "failed",
            scan_result: serializable_hash(scan_result),
            cleanup_result: serializable_hash(cleanup_result),
            audit_result: serializable_hash(audit_result),
            processing_started_at: processing_started_at,
            processed_at: nil,
            duration_ms: duration_ms,
            stage_timings: serializable_hash(stage_timings),
            error_message: truncate_error(error_message),
            created_at: processing_started_at,
            updated_at: Time.current
          },
          unique_by: :index_cluster_processed_blocks_on_height
        )
      end
    rescue StandardError => error
      @logger.error(
        "[cluster_strict_rebuild] failed_checkpoint_persist_failed " \
        "height=#{height} error=#{error.class}: #{error.message}"
      )
    end

    def skipped_cleanup_result
      {
        ok: true,
        skipped: true,
        mode: "outside_strict_path"
      }
    end

    def failed_block_hash(height:)
      checkpoint = ClusterProcessedBlock.find_by(height: height)
      return checkpoint.block_hash if checkpoint&.block_hash.present?

      "layer1_unavailable"
    end

    def measure_checkpoint(timings)
      started_at = monotonic_ms
      yield
    ensure
      timings["checkpoint_ms"] =
        timings.fetch("checkpoint_ms", 0) + (monotonic_ms - started_at)
    end

    def serializable_hash(value)
      value.as_json
    end

    def truncate_error(message)
      message.to_s.first(1_000)
    end

    def failure(height:, stage:, message:, scan_result: nil, cleanup_result: nil, audit_result: nil, backtrace: nil)
      result = {
        ok: false,
        height: height,
        stage: stage,
        message: message,
        scan_result: scan_result,
        cleanup_result: cleanup_result,
        audit_result: audit_result,
        backtrace: backtrace
      }

      @logger.error("[cluster_strict_rebuild] failed #{result.inspect}")

      result
    end

    def measure_stage(stage, timings)
      started_at = monotonic_ms
      result = yield
      timings[stage.to_s] = monotonic_ms - started_at
      result
    rescue StandardError
      timings[stage.to_s] = monotonic_ms - started_at
      raise
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
    end
  end
end
