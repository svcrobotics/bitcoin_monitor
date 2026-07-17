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
      strict_prevout: true,
      strict_io_token: nil
    )
      @from_height = from_height.to_i
      @to_height = to_height.to_i
      @rpc = rpc
      @logger = logger
      @block_verbosity = block_verbosity.to_i
      @strict_prevout = strict_prevout
      @strict_io_token = strict_io_token
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
        unless strict_io_lease_valid?(height)
          failed =
            {
              ok: false,
              height: height,
              stage: "strict_io_lease",
              message: "Strict IO lease is no longer held by Layer1"
            }

          @logger.warn(
            "[layer1_strict_rebuild] strict_io_lease_denied height=#{height}"
          )

          break
        end

        result = process_height(height)
        results << result

        processed += 1 if result[:ok]

        lease_valid_after_block =
          strict_io_lease_valid?(height)

        unless result[:ok]
          failed = result
          break
        end

        unless lease_valid_after_block
          failed =
            {
              ok: false,
              height: height,
              stage: "strict_io_lease_after_block",
              message: "Strict IO lease is no longer held by Layer1 after block"
            }

          @logger.warn(
            "[layer1_strict_rebuild] strict_io_lease_denied_after_block " \
            "height=#{height}"
          )

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

    def strict_io_lease_valid?(height)
      return true if @strict_io_token.blank?

      StrictPipeline::StrictIoLease.renew(
        owner: "layer1",
        token: @strict_io_token
      )
    rescue StandardError => error
      @logger.warn(
        "[layer1_strict_rebuild] strict_io_lease_check_failed " \
        "height=#{height} error=#{error.class}: #{error.message}"
      )

      false
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

      flush_metrics =
        measure_stage(
          stage_timings,
          height,
          "flush_buffers_until_empty"
        ) do
          flush_buffers_until_empty!(
            height: height
          )
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
          strict_rebuild_version: 2,

          block_hash: block_hash,
          tx_count: block_buffer.tx_count,

          processor_mode:
            processor_result[:mode],

          processor_transactions:
            processor_result[:txs],

          processor_errors:
            processor_result[:errors],

          processor_outputs:
            processor_result[:outputs],

          processor_spent_outputs:
            processor_result[:spent_outputs],

          prevout_found:
            processor_result[:prevout_found],

          prevout_missing:
            processor_result[:prevout_missing],

          audit_run_id: outputs_audit.id,
          outputs_audit_status: outputs_audit.status,
          outputs_audit_ok: true,
          inputs_audit_ok: true,
          utxo_audit_ok: true,
          duration_ms: duration_ms,
          rpc_duration_ms: processor_result[:rpc_duration_ms],
          parse_duration_ms: processor_result[:parse_duration_ms],
          flush_duration_ms:
            stage_timings[
              :flush_buffers_until_empty
            ],

          flush_metrics:
            flush_metrics,
          block_verbosity: @block_verbosity,
          strict_prevout: @strict_prevout,
          strict_outputs: strict_outputs_count,
          cluster_inputs: cluster_inputs_count,
          stage_timings: stage_timings,
          node_inputs_count:
            inputs_audit[:node_inputs_count],

          db_inputs_count:
            inputs_audit[:db_inputs_count],

          node_inputs_value_btc:
            inputs_audit[:node_inputs_value_btc],

          db_inputs_value_btc:
            inputs_audit[:db_inputs_value_btc],

          expected_live_outputs_count:
            utxo_audit[:expected_live_outputs_count],

          actual_live_utxos_count:
            utxo_audit[:actual_live_utxos_count],

          expected_live_value_btc:
            utxo_audit[:expected_live_value_btc],

          actual_live_value_btc:
            utxo_audit[:actual_live_value_btc],

          spent_rows_still_in_utxo:
            utxo_audit[:spent_rows_still_in_utxo],

          orphan_utxos_count:
            utxo_audit[:orphan_utxos_count],

          spent_utxos_count:
            utxo_audit[:spent_utxos_count],

          reconcile_spent_outputs:
            reconcile_result,
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
        stage_timings: stage_timings,
        flush_metrics: flush_metrics
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

    def flush_buffers_until_empty!(
      height:
    )
      started_at =
        monotonic_ms

      iterations = []

      10.times do |index|
        iteration =
          index + 1

        outputs_before =
          @redis.llen(
            OUTPUTS_KEY
          )

        spent_before =
          @redis.llen(
            SPENT_KEY
          )

        break if
          outputs_before.zero? &&
          spent_before.zero?

        iteration_started_at =
          monotonic_ms

        @logger.info(
          "[layer1_strict_rebuild] " \
          "flush_iteration_start " \
          "height=#{height} " \
          "iteration=#{iteration} " \
          "outputs_before=#{outputs_before} " \
          "spent_before=#{spent_before}"
        )

        output_started_at =
          monotonic_ms

        output_result =
          Blockchain::Flushers::OutputFlusher
            .new(
              redis: @redis,
              logger: @logger
            )
            .call

        output_duration_ms =
          monotonic_ms -
          output_started_at

        outputs_after_output =
          @redis.llen(
            OUTPUTS_KEY
          )

        @logger.info(
          "[layer1_strict_rebuild] " \
          "output_flusher_done " \
          "height=#{height} " \
          "iteration=#{iteration} " \
          "outputs_flushed=" \
          "#{metric_value(output_result, :flushed).to_i} " \
          "outputs_remaining=#{outputs_after_output}"
        )

        spent_started_at =
          monotonic_ms

        spent_result =
          Blockchain::Flushers::
            SpentOutputFlusherSelector.call(
              redis: @redis,
              mode: :realtime
            )

        spent_duration_ms =
          monotonic_ms -
          spent_started_at

        outputs_remaining =
          @redis.llen(
            OUTPUTS_KEY
          )

        spent_remaining =
          @redis.llen(
            SPENT_KEY
          )

        @logger.info(
          "[layer1_strict_rebuild] " \
          "spent_flusher_done " \
          "height=#{height} " \
          "iteration=#{iteration} " \
          "spent_flushed=" \
          "#{metric_value(spent_result, :flushed).to_i} " \
          "outputs_remaining=#{outputs_remaining} " \
          "spent_remaining=#{spent_remaining}"
        )

        iterations << {
          iteration:
            iteration,

          before: {
            outputs:
              outputs_before,

            spent:
              spent_before
          },

          output:
            normalize_flush_result(
              output_result,
              measured_duration_ms:
                output_duration_ms
            ),

          spent:
            normalize_flush_result(
              spent_result,
              measured_duration_ms:
                spent_duration_ms
            ),

          after: {
            outputs:
              outputs_remaining,

            spent:
              spent_remaining
          },

          duration_ms:
            monotonic_ms -
            iteration_started_at
        }

        break if
          outputs_remaining.zero? &&
          spent_remaining.zero?

        output_progress =
          metric_value(
            output_result,
            :flushed
          ).to_i

        spent_progress =
          metric_value(
            spent_result,
            :flushed
          ).to_i

        if output_progress.zero? &&
           spent_progress.zero?
          raise(
            "Layer1 flush made no progress " \
            "height=#{height} " \
            "outputs=#{outputs_remaining} " \
            "spent=#{spent_remaining}"
          )
        end
      end

      outputs_remaining =
        @redis.llen(
          OUTPUTS_KEY
        )

      spent_remaining =
        @redis.llen(
          SPENT_KEY
        )

      unless outputs_remaining.zero? &&
             spent_remaining.zero?
        raise(
          "Layer1 buffers are not empty " \
          "after flush height=#{height} " \
          "outputs=#{outputs_remaining} " \
          "spent=#{spent_remaining}"
        )
      end

      duration_ms =
        monotonic_ms -
        started_at

      outputs_metrics =
        aggregate_flush_iterations(
          iterations,
          :output
        )

      spent_metrics =
        aggregate_flush_iterations(
          iterations,
          :spent
        )

      result = {
        version: 1,

        duration_ms:
          duration_ms,

        iterations_count:
          iterations.size,

        outputs_rows:
          outputs_metrics[:rows_flushed],

        spent_rows:
          spent_metrics[:rows_flushed],

        cluster_inputs_produced:
          spent_metrics[:cluster_inputs_produced],

        utxos_deleted:
          spent_metrics[:utxos_deleted],

        outputs:
          outputs_metrics,

        spent:
          spent_metrics,

        remaining: {
          outputs:
            outputs_remaining,

          spent:
            spent_remaining
        },

        iterations:
          iterations
      }.compact

      @logger.info(
        "[layer1_strict_rebuild] " \
        "flush_metrics height=#{height} " \
        "#{result.inspect}"
      )

      result
    end

    def normalize_flush_result(
      raw_result,
      measured_duration_ms:
    )
      result =
        raw_result
          .to_h
          .deep_symbolize_keys

      reported_duration_ms =
        numeric_metric(
          result[:duration_ms]
        )

      duration_ms =
        if reported_duration_ms
          reported_duration_ms
        else
          numeric_metric(
            measured_duration_ms
          )
        end

      rows_flushed =
        numeric_metric(
          result[:flushed]
        )

      stage_timings =
        numeric_timing_hash(
          result[:stage_timings]
        )

      slice_timings =
        normalize_slice_timings(
          result[:slice_timings]
        )

      measured_stage_ms =
        Array(stage_timings&.values)
          .sum do |value|
            value
          end

      {
        ok:
          if [true, false].include?(result[:ok])
            result[:ok]
          end,

        rows_flushed:
          rows_flushed,

        duration_ms:
          duration_ms,

        measured_duration_ms:
          numeric_metric(measured_duration_ms),

        ms_per_row:
          if rows_flushed&.positive? && duration_ms
            (
              duration_ms.to_f /
              rows_flushed
            ).round(3)
          end,

        stage_timings:
          stage_timings,

        slice_timings:
          slice_timings,

        cluster_inputs_produced:
          numeric_metric(
            result[:cluster_inserted]
          ),

        utxos_deleted:
          numeric_metric(
            result[:utxo_deleted]
          ),

        missing_utxos:
          numeric_metric(
            result[:missing_utxo]
          ),

        unattributed_duration_ms:
          if stage_timings && duration_ms
            [
              duration_ms -
                measured_stage_ms,
              0
            ].max
          end
      }.compact
    end

    def aggregate_flush_iterations(
      iterations,
      key
    )
      entries =
        iterations.map do |iteration|
          iteration.fetch(
            key
          )
        end

      rows_flushed =
        sum_numeric_metrics(
          entries,
          :rows_flushed
        )

      duration_ms =
        sum_numeric_metrics(
          entries,
          :duration_ms
        )

      cluster_inputs_produced =
        sum_numeric_metrics(
          entries,
          :cluster_inputs_produced
        )

      utxos_deleted =
        sum_numeric_metrics(
          entries,
          :utxos_deleted
        )

      stage_timings =
        Hash.new(0)

      entries.each do |entry|
        (
          entry[
            :stage_timings
          ] || {}
        ).each do |stage, value|
          stage_timings[
            stage.to_sym
          ] += value
        end
      end

      slice_timings =
        entries.flat_map do |entry|
          Array(
            entry[:slice_timings]
          )
        end

      {
        calls:
          entries.size,

        rows_flushed:
          rows_flushed,

        duration_ms:
          duration_ms,

        ms_per_row:
          if rows_flushed&.positive? && duration_ms
            (
              duration_ms.to_f /
              rows_flushed
            ).round(3)
          end,

        stage_timings:
          stage_timings.presence,

        slice_timings:
          slice_timings.presence,

        cluster_inputs_produced:
          cluster_inputs_produced,

        utxos_deleted:
          utxos_deleted,

        unattributed_duration_ms:
          sum_numeric_metrics(
            entries,
            :unattributed_duration_ms
          )
      }.compact
    end

    def numeric_metric(value)
      return value if value.is_a?(Integer)
      return value.to_f if value.is_a?(Numeric)

      nil
    end

    def numeric_timing_hash(value)
      return nil unless value.respond_to?(:to_h)

      timings =
        value
          .to_h
          .each_with_object({}) do |(stage, duration), result|
            numeric_duration =
              numeric_metric(duration)

            next unless numeric_duration

            result[stage.to_sym] =
              numeric_duration
          end

      timings.presence
    end

    def normalize_slice_timings(value)
      return nil unless value.is_a?(Array)

      slices =
        value.filter_map do |raw_slice|
          next unless raw_slice.respond_to?(:to_h)

          slice =
            raw_slice
              .to_h
              .deep_symbolize_keys

          normalized = {
            slice:
              numeric_metric(slice[:slice]),

            rows:
              numeric_metric(slice[:rows]),

            duration_ms:
              numeric_metric(slice[:duration_ms]),

            timings:
              numeric_timing_hash(slice[:timings])
          }.compact

          normalized.presence
        end

      slices.presence
    end

    def sum_numeric_metrics(entries, key)
      values =
        entries.filter_map do |entry|
          numeric_metric(
            entry[key]
          )
        end

      values.sum if values.any?
    end

    def metric_value(
      hash,
      key
    )
      return nil unless
        hash.respond_to?(
          :key?
        )

      return hash[key] if
        hash.key?(
          key
        )

      hash[
        key.to_s
      ]
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
      true
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
