# frozen_string_literal: true

module Clusters
  class StrictWindowRebuilder
    class Error < StandardError; end
    class EnclosingTransactionError < Error; end
    class Layer1BlockUnavailable < Error; end
    class BlockHashChanged < Error; end
    class CheckpointHashMismatch < Error; end
    class AuditFailed < Error; end
    class GuardFailed < Error; end

    def self.call(from_height:, to_height:, yield_guard: nil)
      new(
        from_height: from_height,
        to_height: to_height,
        yield_guard: yield_guard
      ).call
    end

    def initialize(from_height:, to_height:, yield_guard: nil, logger: Rails.logger)
      @from_height = Integer(from_height)
      @to_height = Integer(to_height)
      @yield_guard = yield_guard
      @logger = logger
    end

    def call
      reject_enclosing_transaction!
      raise ArgumentError, "invalid Cluster certification window" if @from_height.negative? || @to_height < @from_height

      results = []
      (@from_height..@to_height).each do |height|
        decision = guard_decision(height)
        unless decision[:allowed]
          return window_result(results, status: "preempted", next_height: height)
        end

        results << process_height(height)
      end

      window_result(results, status: "processed")
    end

    private

    def process_height(height)
      expected_hash = expected_block_hash!(height)
      started_at = monotonic_ms
      result = nil

      ApplicationRecord.transaction(
        isolation: :repeatable_read,
        requires_new: true
      ) do
        block = lock_layer1_block!(height, expected_hash: expected_hash)
        checkpoint = lock_checkpoint!(height, block_hash: expected_hash)

        if checkpoint.status == "processed"
          raise CheckpointHashMismatch,
            "Cluster checkpoint hash differs at height #{height}" if checkpoint.block_hash != expected_hash

          handoff_result = register_actor_profile_handoffs!(
            height: height,
            block_hash: expected_hash,
            clusters_touched: checkpoint.scan_result.deep_symbolize_keys.fetch(:clusters_touched, [])
          )
          result = idempotent_result(checkpoint, handoff_result: handoff_result)
          next
        end

        if checkpoint.block_hash.present? && checkpoint.block_hash != expected_hash
          raise CheckpointHashMismatch,
            "Cluster checkpoint hash differs at height #{height}"
        end

        processing_started_at = Time.current
        checkpoint.update!(
          block_hash: expected_hash,
          status: "processing",
          processing_started_at: processing_started_at,
          processed_at: nil,
          error_message: nil
        )

        scan_started_at = monotonic_ms
        scan_result = ClusterScanner.call(height: height, mode: :batch)
        scan_ms = monotonic_ms - scan_started_at

        audit_started_at = monotonic_ms
        audit_result = Clusters::AuditBlock.call(height: height)
        audit_ms = monotonic_ms - audit_started_at
        raise AuditFailed, "Cluster audit failed at height #{height}" unless audit_result[:ok]

        handoff_result = register_actor_profile_handoffs!(
          height: height,
          block_hash: expected_hash,
          clusters_touched: scan_result.fetch(:clusters_touched)
        )

        duration_ms = monotonic_ms - started_at
        stage_timings = {
          "scan_ms" => scan_ms,
          "audit_ms" => audit_ms,
          "transaction_ms" => duration_ms
        }
        mark_processed!(
          checkpoint,
          scan_result: scan_result,
          audit_result: audit_result,
          duration_ms: duration_ms,
          stage_timings: stage_timings
        )

        result = {
          ok: true,
          height: height,
          block_hash: block.block_hash,
          status: "processed",
          scanner: scan_result,
          audit: audit_result,
          actor_profile_handoffs: handoff_result,
          clusters_touched: scan_result.fetch(:clusters_touched),
          duration_ms: duration_ms,
          transaction_duration_ms: duration_ms,
          stage_timings: stage_timings
        }
      end

      result
    rescue StandardError => original_error
      failure_hash = expected_hash.presence || BlockBufferModel.where(height: height).pick(:block_hash)
      begin
        persist_failed_checkpoint(
          height: height,
          block_hash: failure_hash,
          error: original_error
        ) unless original_error.is_a?(CheckpointHashMismatch)
      rescue StandardError => persistence_error
        @logger.error(
          "[cluster_strict_rebuild] failed_checkpoint_unavailable " \
          "height=#{height} error_class=#{persistence_error.class.name}"
        )
      end
      raise original_error
    end

    def expected_block_hash!(height)
      block_hash, status = BlockBufferModel.where(height: height).pick(:block_hash, :status)
      unless block_hash.present? && status == "processed"
        raise Layer1BlockUnavailable,
          "Layer1 block is not processed at height #{height}"
      end
      block_hash
    end

    def lock_layer1_block!(height, expected_hash:)
      block = BlockBufferModel.lock.find_by(height: height)
      unless block&.status == "processed"
        raise Layer1BlockUnavailable,
          "Layer1 block is not processed at height #{height}"
      end
      unless block.height == height && block.block_hash == expected_hash
        raise BlockHashChanged,
          "Layer1 block hash changed at height #{height}"
      end
      block
    end

    def lock_checkpoint!(height, block_hash:)
      ClusterProcessedBlock.lock.find_or_create_by!(height: height) do |checkpoint|
        checkpoint.block_hash = block_hash
        checkpoint.status = "processing"
        checkpoint.scan_result = {}
        checkpoint.cleanup_result = {}
        checkpoint.audit_result = {}
        checkpoint.stage_timings = {}
      end
    end

    def mark_processed!(checkpoint, scan_result:, audit_result:, duration_ms:, stage_timings:)
      checkpoint.update!(
        status: "processed",
        scan_result: scan_result,
        cleanup_result: {},
        audit_result: audit_result,
        processed_at: Time.current,
        duration_ms: duration_ms,
        stage_timings: stage_timings,
        error_message: nil
      )
    end

    def persist_failed_checkpoint(height:, block_hash:, error:)
      return if block_hash.blank?

      ApplicationRecord.transaction(requires_new: true) do
        checkpoint = ClusterProcessedBlock.lock.find_or_initialize_by(height: height)
        return if checkpoint.persisted? && checkpoint.status == "processed"

        checkpoint.assign_attributes(
          block_hash: block_hash,
          status: "failed",
          scan_result: {},
          cleanup_result: {},
          audit_result: {},
          processed_at: nil,
          duration_ms: nil,
          stage_timings: {},
          error_message: error.class.name,
          processing_started_at: nil
        )
        checkpoint.save!
      end
    rescue StandardError => persistence_error
      @logger.error(
        "[cluster_strict_rebuild] failed_checkpoint_unavailable " \
        "height=#{height} error_class=#{persistence_error.class.name}"
      )
    end

    def register_actor_profile_handoffs!(height:, block_hash:, clusters_touched:)
      Clusters::ActorProfileHandoffRegister.call(
        cluster_height: height,
        block_hash: block_hash,
        clusters_touched: clusters_touched
      )
    end

    def idempotent_result(checkpoint, handoff_result:)
      scan_result = checkpoint.scan_result.deep_symbolize_keys
      audit_result = checkpoint.audit_result.deep_symbolize_keys
      {
        ok: true,
        height: checkpoint.height,
        block_hash: checkpoint.block_hash,
        status: "processed",
        skipped: true,
        reason: "already_processed",
        scanner: scan_result,
        audit: audit_result,
        actor_profile_handoffs: handoff_result,
        clusters_touched: scan_result.fetch(:clusters_touched, []),
        duration_ms: checkpoint.duration_ms,
        transaction_duration_ms: 0,
        stage_timings: checkpoint.stage_timings
      }
    end

    def guard_decision(height)
      return { allowed: true } unless @yield_guard

      decision = @yield_guard.call(height)
      return decision if decision.is_a?(Hash) && [true, false].include?(decision[:allowed])

      raise GuardFailed, "Cluster guard returned an invalid decision"
    rescue GuardFailed
      raise
    rescue StandardError => error
      raise GuardFailed,
        "Cluster guard failed with #{error.class.name}"
    end

    def reject_enclosing_transaction!
      return unless ApplicationRecord.connection.transaction_open?

      raise EnclosingTransactionError,
        "Cluster certification requires its own top-level PostgreSQL transaction"
    end

    def window_result(results, status:, next_height: nil)
      payload = {
        ok: true,
        status: status,
        from_height: @from_height,
        to_height: @to_height,
        processed: results.size,
        next_height: next_height,
        results: results
      }
      return payload unless results.one? && @from_height == @to_height

      payload.merge(results.first)
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
    end
  end
end
