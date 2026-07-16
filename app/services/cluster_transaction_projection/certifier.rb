# frozen_string_literal: true

module ClusterTransactionProjection
  class Certifier
    def self.call(generation)
      new(generation).call
    end

    def initialize(generation)
      @generation =
        generation.is_a?(
          ClusterTransactionProjectionGeneration
        ) ? generation : ClusterTransactionProjectionGeneration.find(generation)
    end

    def call
      ApplicationRecord.transaction do
        locked_generation =
          ClusterTransactionProjectionGeneration
            .lock
            .find(generation.id)

        cluster =
          Cluster.lock.find(locked_generation.cluster_id)

        unless cluster.composition_version.to_i ==
               locked_generation.composition_version.to_i
          mark_stale!(
            locked_generation,
            "composition_revision_changed"
          )

          return refused(
            locked_generation,
            :composition_mismatch
          )
        end

        checkpoint =
          ClusterProcessedBlock.find_by(
            height: locked_generation.checkpoint_height
          )

        unless checkpoint&.status.to_s == "processed"
          fail_generation!(
            locked_generation,
            "cluster_checkpoint_missing"
          )

          return refused(
            locked_generation,
            :checkpoint_missing
          )
        end

        unless checkpoint.block_hash.to_s ==
               locked_generation.checkpoint_hash.to_s
          mark_stale!(
            locked_generation,
            "checkpoint_hash_mismatch"
          )

          return refused(
            locked_generation,
            :checkpoint_hash_mismatch
          )
        end

        counts =
          CounterAudit.compute_counts(
            locked_generation
          )

        publish_certified!(
          generation: locked_generation,
          counts: counts
        )

        Result.new(
          ok: true,
          reason: :certified,
          generation: locked_generation
        )
      end
    end

    private

    attr_reader :generation

    def mark_stale!(generation, reason)
      generation.update!(
        status: "stale",
        stale_reason: reason,
        stale_at: Time.current,
        last_error: nil
      )
    end

    def fail_generation!(generation, reason)
      generation.update!(
        status: "failed",
        failed_at: Time.current,
        last_error: reason
      )
    end

    def refused(generation, reason)
      Result.new(
        ok: false,
        reason: reason,
        generation: generation
      )
    end

    def publish_certified!(generation:, counts:)
      now = Time.current

      ClusterTransactionProjectionGeneration
        .where(
          cluster_id: generation.cluster_id,
          status: "certified"
        )
        .where.not(id: generation.id)
        .update_all(
          status: "replaced",
          updated_at: now
        )

      generation.update!(
        status: "certified",
        inflow_count: counts.fetch(:inflow_count),
        outflow_count: counts.fetch(:outflow_count),
        tx_count: counts.fetch(:tx_count),
        facts_count: counts.fetch(:facts_count),
        certified_at: now,
        last_error: nil
      )
    end

    Result = Struct.new(
      :ok,
      :reason,
      :generation,
      keyword_init: true
    )
  end
end
