# frozen_string_literal: true

module ClusterTransactionProjection
  # Advances only existing certified generations whose Cluster composition is
  # unchanged. New clusters, replacement generations, reorgs and backfills are
  # deliberately outside this dispatcher.
  class IncrementalDispatcher
    DEFAULT_LIMIT = 25
    MAX_LIMIT = 100
    ADVISORY_LOCK_NAMESPACE = 0x4354_5000_0000_0000

    class BatchError < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("one or more incremental CTP candidates failed")
      end
    end

    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    def initialize(limit: DEFAULT_LIMIT)
      @limit = Integer(limit)
      raise ArgumentError, "limit must be positive" unless @limit.positive?
      raise ArgumentError, "limit exceeds #{MAX_LIMIT}" if @limit > MAX_LIMIT
    end

    def call
      results = candidate_ids.map { |generation_id| process_candidate(generation_id) }
      batch = build_result(results)
      raise BatchError, batch unless batch.ok

      batch
    end

    private

    attr_reader :limit

    def candidate_ids
      tip = certified_cluster_tip
      return [] unless tip

      sql = <<~SQL.squish
        SELECT generations.id
        FROM cluster_transaction_projection_generations generations
        LEFT JOIN clusters
          ON clusters.id = generations.cluster_id
        LEFT JOIN cluster_processed_blocks current_checkpoints
          ON current_checkpoints.height = generations.checkpoint_height
        LEFT JOIN cluster_transaction_projection_blocks projected_blocks
          ON projected_blocks.block_height = generations.checkpoint_height
        WHERE generations.status = 'certified'
          AND (
            generations.checkpoint_height < #{Integer(tip)}
            OR clusters.id IS NULL
            OR clusters.composition_version <> generations.composition_version
            OR current_checkpoints.id IS NULL
            OR current_checkpoints.status <> 'processed'
            OR current_checkpoints.processed_at IS NULL
            OR NOT (current_checkpoints.audit_result @> '{"ok": true}'::jsonb)
            OR current_checkpoints.block_hash <> generations.checkpoint_hash
            OR projected_blocks.id IS NULL
            OR projected_blocks.status <> 'projected'
            OR projected_blocks.block_hash <> generations.checkpoint_hash
          )
        ORDER BY generations.checkpoint_height, generations.cluster_id, generations.id
        LIMIT #{Integer(limit)}
      SQL

      ApplicationRecord.connection.select_values(sql).map(&:to_i)
    end

    def certified_cluster_tip
      ClusterProcessedBlock
        .where(status: "processed")
        .where.not(processed_at: nil)
        .where("audit_result @> ?::jsonb", { ok: true }.to_json)
        .maximum(:height)
    end

    def process_candidate(generation_id)
      ApplicationRecord.connection_pool.with_connection do |connection|
        key = advisory_lock_key(generation_id)
        acquired = advisory_lock(connection, key)
        return excluded(generation_id, :advisory_lock_busy) unless acquired

        result = nil
        begin
          result = process_locked_candidate(generation_id)
        rescue StandardError => error
          result = failed(generation_id, :candidate_error, error.class.name)
        ensure
          begin
            advisory_unlock(connection, key)
          rescue StandardError => unlock_error
            result = failed(
              generation_id,
              :advisory_unlock_failed,
              unlock_error.class.name
            ) unless result&.status == :failed
          end
        end
        result
      end
    end

    def process_locked_candidate(generation_id)
      generation = ClusterTransactionProjectionGeneration.find_by(id: generation_id)
      return excluded(generation_id, :reconstruction_required) unless
        generation&.status == "certified"

      cluster = Cluster.find_by(id: generation.cluster_id)
      return excluded(generation_id, :reconstruction_required) unless cluster
      return excluded_for(generation, :composition_changed) unless
        cluster.composition_version == generation.composition_version

      return excluded_for(generation, :checkpoint_not_canonical) unless
        current_checkpoint_canonical?(generation)

      next_height = generation.checkpoint_height + 1
      checkpoint = ClusterProcessedBlock.find_by(height: next_height)
      return excluded_for(generation, :next_height_missing, next_height: next_height) unless
        next_checkpoint_certified?(checkpoint)

      activity = CertifiedBlockActivity.call(
        cluster_id: generation.cluster_id,
        expected_composition_version: generation.composition_version,
        block_height: next_height,
        block_hash: checkpoint.block_hash
      )
      return activity_refused(generation, next_height, checkpoint, activity) unless activity.ok

      application = ApplyBlock.call(
        cluster_id: generation.cluster_id,
        expected_composition_version: activity.expected_composition_version,
        block_height: next_height,
        block_hash: checkpoint.block_hash,
        received_txids: activity.received_txids,
        spent_txids: activity.spent_txids
      )

      application_result(generation, next_height, checkpoint, application)
    end

    def current_checkpoint_canonical?(generation)
      checkpoint = ClusterProcessedBlock.find_by(height: generation.checkpoint_height)
      projected = ClusterTransactionProjectionBlock.find_by(
        block_height: generation.checkpoint_height
      )

      checkpoint&.status == "processed" &&
        checkpoint.processed_at.present? &&
        checkpoint.audit_result.to_h["ok"] == true &&
        checkpoint.block_hash == generation.checkpoint_hash &&
        projected&.status == "projected" &&
        projected.block_hash == generation.checkpoint_hash
    end

    def next_checkpoint_certified?(checkpoint)
      checkpoint&.status == "processed" &&
        checkpoint.processed_at.present? &&
        checkpoint.audit_result.to_h["ok"] == true &&
        checkpoint.block_hash.present?
    end

    def activity_refused(generation, height, checkpoint, activity)
      mapped = case activity.reason
      when :composition_mismatch then :composition_changed
      when :block_hash_mismatch, :orphaned_block then :checkpoint_not_canonical
      when :layer1_not_certified, :cluster_not_certified then :next_height_missing
      end
      return excluded_for(generation, mapped, next_height: height, block_hash: checkpoint.block_hash) if mapped

      failed_for(
        generation,
        :certified_activity_refused,
        detail: activity.reason,
        next_height: height,
        block_hash: checkpoint.block_hash
      )
    end

    def application_result(generation, height, checkpoint, application)
      if application.ok
        status = application.reason == :already_projected ? :already_projected : :projected
        return candidate_result(
          generation,
          status: status,
          reason: application.reason,
          next_height: height,
          block_hash: checkpoint.block_hash
        )
      end

      mapped = case application.reason
      when :expected_composition_mismatch, :composition_mismatch
        :composition_changed
      when :missing_generation, :ambiguous_certified_generation
        :reconstruction_required
      when :checkpoint_missing, :projection_gap
        :next_height_missing
      when :hash_mismatch, :stale
        :checkpoint_not_canonical
      end
      return excluded_for(generation, mapped, next_height: height, block_hash: checkpoint.block_hash) if mapped

      failed_for(
        generation,
        :apply_block_refused,
        detail: application.reason,
        next_height: height,
        block_hash: checkpoint.block_hash
      )
    end

    def advisory_lock(connection, key)
      ActiveModel::Type::Boolean.new.cast(
        connection.select_value("SELECT pg_try_advisory_lock(#{Integer(key)})")
      )
    end

    def advisory_unlock(connection, key)
      released = ActiveModel::Type::Boolean.new.cast(
        connection.select_value("SELECT pg_advisory_unlock(#{Integer(key)})")
      )
      raise "incremental CTP advisory lock was not owned" unless released
    end

    def advisory_lock_key(generation_id)
      ADVISORY_LOCK_NAMESPACE + Integer(generation_id)
    end

    def excluded(generation_id, reason)
      CandidateResult.new(
        generation_id: generation_id,
        status: :excluded,
        reason: reason
      )
    end

    def excluded_for(generation, reason, **attributes)
      candidate_result(generation, status: :excluded, reason: reason, **attributes)
    end

    def failed(generation_id, reason, error_class)
      CandidateResult.new(
        generation_id: generation_id,
        status: :failed,
        reason: reason,
        error_class: error_class
      )
    end

    def failed_for(generation, reason, detail:, **attributes)
      candidate_result(
        generation,
        status: :failed,
        reason: reason,
        detail: detail,
        **attributes
      )
    end

    def candidate_result(generation, **attributes)
      CandidateResult.new(
        generation_id: generation.id,
        cluster_id: generation.cluster_id,
        expected_composition_version: generation.composition_version,
        **attributes
      )
    end

    def build_result(results)
      BatchResult.new(
        ok: results.none? { |result| result.status == :failed },
        selected: results.size,
        projected: results.count { |result| result.status == :projected },
        already_projected: results.count { |result| result.status == :already_projected },
        excluded: results.count { |result| result.status == :excluded },
        failed: results.count { |result| result.status == :failed },
        candidates: results
      )
    end

    CandidateResult = Struct.new(
      :generation_id,
      :cluster_id,
      :expected_composition_version,
      :next_height,
      :block_hash,
      :status,
      :reason,
      :detail,
      :error_class,
      keyword_init: true
    )

    BatchResult = Struct.new(
      :ok,
      :selected,
      :projected,
      :already_projected,
      :excluded,
      :failed,
      :candidates,
      keyword_init: true
    )
  end
end
