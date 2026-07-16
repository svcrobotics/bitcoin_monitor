# frozen_string_literal: true

module ClusterTransactionProjection
  class Readiness
    STATUSES =
      %i[
        ready
        missing
        building
        behind_checkpoint
        composition_mismatch
        invalid_composition_revision
        ambiguous_certified_generation
        projection_gap
        hash_mismatch
        stale
        failed
      ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(
      cluster_id:,
      cluster_checkpoint:,
      composition_version:
    )
      @cluster_id = cluster_id.to_i
      @cluster_checkpoint = cluster_checkpoint.to_i
      @composition_version = composition_version.to_i
    end

    def call
      return result(:invalid_composition_revision, nil) if
        composition_version < 1

      certified_generations =
        ClusterTransactionProjectionGeneration
          .where(cluster_id: cluster_id, status: "certified")
          .to_a

      return result(:ambiguous_certified_generation, nil) if
        certified_generations.size > 1

      generation =
        certified_generations.first || latest_for_composition

      return result(status_without_exact_generation, nil) unless
        generation

      return result(:building, generation) if
        generation.status == "building" ||
        generation.status == "pending"

      return result(:stale, generation) if generation.stale?
      return result(:failed, generation) if generation.failed?
      return result(:missing, generation) if generation.replaced?

      unless generation.certified?
        return result(:missing, generation)
      end

      return result(:invalid_composition_revision, generation) if
        generation.composition_version.to_i < 1

      unless generation.composition_version.to_i ==
             composition_version
        return result(:composition_mismatch, generation)
      end

      if generation.checkpoint_height.to_i < cluster_checkpoint
        return result(:behind_checkpoint, generation)
      end

      hash_result =
        verify_hashes(generation)

      return hash_result unless hash_result.ok

      gap_result =
        verify_no_projection_gap(generation)

      return gap_result unless gap_result.ok

      result(:ready, generation)
    end

    private

    attr_reader(
      :cluster_id,
      :cluster_checkpoint,
      :composition_version
    )

    def latest_for_composition
      ClusterTransactionProjectionGeneration
        .where(
          cluster_id: cluster_id,
          composition_version: composition_version
        )
        .order(id: :desc)
        .first
    end

    def status_without_exact_generation
      any_generation =
        ClusterTransactionProjectionGeneration
          .where(cluster_id: cluster_id)
          .exists?

      any_generation ? :composition_mismatch : :missing
    end

    def result(status, generation)
      Result.new(
        status: status,
        generation: generation
      )
    end

    def verify_hashes(generation)
      checkpoint =
        ClusterProcessedBlock.find_by(
          height: generation.checkpoint_height
        )

      unless checkpoint&.block_hash.to_s ==
             generation.checkpoint_hash.to_s
        return result(:hash_mismatch, generation)
      end

      if generation.checkpoint_height.to_i >
         generation.base_checkpoint_height.to_i
        projection_block =
          ClusterTransactionProjectionBlock.find_by(
            block_height: generation.checkpoint_height
          )

        unless projection_block&.status == "projected" &&
               projection_block.block_hash.to_s ==
                 generation.checkpoint_hash.to_s
          return result(:hash_mismatch, generation)
        end
      end

      result(:ready, generation)
    end

    def verify_no_projection_gap(generation = current_generation)
      return result(:ready, nil) if cluster_checkpoint < 0

      base_checkpoint =
        generation&.base_checkpoint_height.to_i

      return result(:ready, nil) if cluster_checkpoint <= base_checkpoint

      sql = <<~SQL.squish
        SELECT COUNT(*) AS gaps
        FROM generate_series(
          #{Integer(base_checkpoint) + 1},
          #{Integer(cluster_checkpoint)}
        ) AS heights(height)
        LEFT JOIN cluster_transaction_projection_blocks blocks
          ON blocks.block_height = heights.height
         AND blocks.status = 'projected'
        WHERE blocks.id IS NULL
      SQL

      gaps =
        ActiveRecord::Base.connection
          .select_value(sql)
          .to_i

      return result(:projection_gap, nil) if gaps.positive?

      result(:ready, nil)
    end

    def current_generation
      ClusterTransactionProjectionGeneration
        .where(cluster_id: cluster_id, status: "certified")
        .first
    end

    class Result
      attr_reader :status, :generation

      def initialize(status:, generation:)
        @status = status.to_sym
        @generation = generation
      end

      def ready?
        status == :ready
      end

      def ok
        ready?
      end

      def counts
        return nil unless ready?

        {
          inflow_count: generation.inflow_count.to_i,
          outflow_count: generation.outflow_count.to_i,
          tx_count: generation.tx_count.to_i
        }
      end
    end
  end
end
