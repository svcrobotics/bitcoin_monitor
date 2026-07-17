# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    class Build
      VERSION =
        "actor_behavior_heavy_build_v2"

      DEFAULT_SWEEP_WINDOW_BLOCKS =
        3_000

      DEFAULT_DISTRIBUTION_WINDOW_BLOCKS =
        500

      def self.call(
        source_cluster_id:,
        sweep_window_blocks:
          DEFAULT_SWEEP_WINDOW_BLOCKS,
        distribution_window_blocks:
          DEFAULT_DISTRIBUTION_WINDOW_BLOCKS,
        to_height: nil
      )
        new(
          source_cluster_id:
            source_cluster_id,

          sweep_window_blocks:
            sweep_window_blocks,

          distribution_window_blocks:
            distribution_window_blocks,

          to_height:
            to_height
        ).call
      end

      def initialize(
        source_cluster_id:,
        sweep_window_blocks:,
        distribution_window_blocks:,
        to_height:
      )
        @source_cluster_id =
          source_cluster_id.to_i

        @sweep_window_blocks =
          [
            sweep_window_blocks.to_i,
            1
          ].max

        @distribution_window_blocks =
          [
            distribution_window_blocks.to_i,
            1
          ].max

        @requested_to_height =
          to_height&.to_i
      end

      def call
        strict_snapshot =
          ActorBehaviorSnapshot.find_by(
            cluster_id:
              source_cluster_id,

            status:
              "certified"
          )

        unless strict_snapshot
          return deferred(
            stage: :strict_snapshot,
            reason:
              :strict_behavior_snapshot_missing
          )
        end

        resolved_to_height =
          requested_to_height ||
          BlockBufferModel
            .where(status: "processed")
            .maximum(:height)
            .to_i

        if resolved_to_height <= 0
          return deferred(
            stage: :checkpoint,
            reason:
              :processed_height_missing
          )
        end

        sweep_from_height =
          [
            resolved_to_height -
              sweep_window_blocks +
              1,
            0
          ].max

        distribution_from_height =
          [
            resolved_to_height -
              distribution_window_blocks +
              1,
            0
          ].max

        deposit_result =
          DepositEvidence.call(
            actor_profile:
              strict_snapshot.actor_profile
          )

        return propagate(
          :deposit,
          deposit_result
        ) unless certified?(
          deposit_result
        )

        sweep_chunk_size =
          ENV.fetch(
            "ACTOR_BEHAVIOR_HEAVY_SWEEP_CHUNK_SIZE",
            ActorBehaviors::Heavy::
              SegmentedSweepRelationEvidence::
              DEFAULT_CHUNK_SIZE.to_s
          ).to_i.clamp(
            50,
            1_000
          )

        sweep_result =
          SegmentedSweepRelationEvidence.call(
            source_cluster_id:
              source_cluster_id,

            from_height:
              sweep_from_height,

            to_height:
              resolved_to_height,

            chunk_size:
              sweep_chunk_size
          )

        return propagate(
          :sweep,
          sweep_result
        ) unless certified?(
          sweep_result
        )

        downstream_cluster_id =
          sweep_result
            .fetch(:evidence)
            .fetch(
              :top_destination_cluster_id
            )
            .to_i

        distribution_chunk_size =
          ENV.fetch(
            "ACTOR_BEHAVIOR_HEAVY_CHUNK_SIZE",
            ActorBehaviors::Heavy::
              SegmentedDownstreamDistributionEvidence::
              DEFAULT_CHUNK_SIZE.to_s
          ).to_i.clamp(
            10,
            500
          )

        distribution_result =
          SegmentedDownstreamDistributionEvidence.call(
            cluster_id:
              downstream_cluster_id,

            from_height:
              distribution_from_height,

            to_height:
              resolved_to_height,

            chunk_size:
              distribution_chunk_size
          )

        return propagate(
          :distribution,
          distribution_result
        ) unless certified?(
          distribution_result
        )

        distribution_evidence =
          distribution_result.fetch(
            :evidence
          )

        sweep_evidence =
          sweep_result
            .fetch(:evidence)
            .merge(
              destination_spending_transactions:
                distribution_evidence.fetch(
                  :spending_transactions
                ),

              destination_spending_blocks:
                distribution_evidence.fetch(
                  :spending_blocks
                )
            )

        persist_result =
          BuildFromEvidence.call(
            source_cluster_id:
              source_cluster_id,

            downstream_cluster_id:
              downstream_cluster_id,

            window_from_height:
              sweep_from_height,

            window_to_height:
              resolved_to_height,

            deposit_evidence:
              deposit_result.fetch(
                :evidence
              ),

            sweep_evidence:
              sweep_evidence,

            distribution_evidence:
              distribution_evidence,

            provenance: {
              builder_version:
                VERSION,

              deposit_evidence_version:
                DepositEvidence::VERSION,

              sweep_evidence_version:
                SegmentedSweepRelationEvidence::
                  VERSION,

              sweep_chunk_size:
                sweep_chunk_size,

              distribution_evidence_version:
                SegmentedDownstreamDistributionEvidence::
                  VERSION,

              distribution_chunk_size:
                distribution_chunk_size,

              sweep_window_blocks:
                sweep_window_blocks,

              distribution_window_blocks:
                distribution_window_blocks,

              sweep_window: {
                from_height:
                  sweep_from_height,

                to_height:
                  resolved_to_height
              },

              distribution_window: {
                from_height:
                  distribution_from_height,

                to_height:
                  resolved_to_height
              },

              source_fact_tables: %w[
                actor_profiles
                addresses
                cluster_inputs
                utxo_outputs
              ]
            }
          )

        persist_result.merge(
          builder_version:
            VERSION,

          stages: {
            deposit:
              "certified",

            sweep:
              "certified",

            distribution:
              "certified",

            persistence:
              persist_result[
                :status
              ]
          }
        )
      rescue StandardError => error
        {
          ok: false,
          status: "failed",
          stage: :orchestrator,
          reason: :calculation_failed,
          error_class: error.class.name,
          error_message: error.message
        }
      end

      private

      attr_reader(
        :source_cluster_id,
        :sweep_window_blocks,
        :distribution_window_blocks,
        :requested_to_height
      )

      def certified?(result)
        result[:ok] &&
          result[:status] ==
            "certified"
      end

      def propagate(stage, result)
        result.merge(
          stage:
            stage,

          source_cluster_id:
            source_cluster_id
        )
      end

      def deferred(stage:, reason:)
        {
          ok: true,
          status: "deferred",
          stage: stage,
          reason: reason,
          source_cluster_id:
            source_cluster_id
        }
      end
    end
  end
end
