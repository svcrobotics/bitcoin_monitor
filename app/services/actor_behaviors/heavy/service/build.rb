# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    module Service
      class Build
        VERSION =
          "actor_behavior_heavy_service_build_v1"

        DEFAULT_DISTRIBUTION_WINDOW_BLOCKS =
          500

        DEFAULT_DISTRIBUTION_CHUNK_SIZE =
          DirectDistributionEvidence::
            DEFAULT_CHUNK_SIZE

        def self.call(
          source_cluster_id:,
          distribution_window_blocks:
            DEFAULT_DISTRIBUTION_WINDOW_BLOCKS,
          distribution_chunk_size: nil,
          to_height: nil,
          profile_builder: ProfileEvidence,
          distribution_builder:
            DirectDistributionEvidence,
          persister: BuildFromEvidence
        )
          new(
            source_cluster_id:
              source_cluster_id,

            distribution_window_blocks:
              distribution_window_blocks,

            distribution_chunk_size:
              distribution_chunk_size,

            to_height:
              to_height,

            profile_builder:
              profile_builder,

            distribution_builder:
              distribution_builder,

            persister:
              persister
          ).call
        end

        def initialize(
          source_cluster_id:,
          distribution_window_blocks:,
          distribution_chunk_size:,
          to_height:,
          profile_builder:,
          distribution_builder:,
          persister:
        )
          @source_cluster_id =
            source_cluster_id.to_i

          @distribution_window_blocks =
            [
              distribution_window_blocks.to_i,
              1
            ].max

          @distribution_chunk_size =
            resolve_chunk_size(
              distribution_chunk_size
            )

          @requested_to_height =
            to_height&.to_i

          @profile_builder =
            profile_builder

          @distribution_builder =
            distribution_builder

          @persister =
            persister
        end

        def call
          strict_snapshot =
            ActorBehaviorSnapshot
              .includes(:actor_profile)
              .find_by(
                cluster_id:
                  source_cluster_id,

                status:
                  "certified"
              )

          unless strict_snapshot
            return deferred(
              stage:
                :strict_snapshot,

              reason:
                :strict_behavior_snapshot_missing
            )
          end

          resolved_to_height =
            requested_to_height ||
            processed_height

          if resolved_to_height <= 0
            return deferred(
              stage:
                :checkpoint,

              reason:
                :processed_height_missing
            )
          end

          from_height =
            [
              resolved_to_height -
                distribution_window_blocks +
                1,
              0
            ].max

          profile_result =
            profile_builder.call(
              actor_profile:
                strict_snapshot.actor_profile
            )

          return propagate(
            stage:
              :profile,

            result:
              profile_result
          ) unless certified?(
            profile_result
          )

          distribution_result =
            distribution_builder.call(
              cluster_id:
                source_cluster_id,

              from_height:
                from_height,

              to_height:
                resolved_to_height,

              chunk_size:
                distribution_chunk_size
            )

          return propagate(
            stage:
              :direct_distribution,

            result:
              distribution_result
          ) unless certified?(
            distribution_result
          )

          persist_result =
            persister.call(
              source_cluster_id:
                source_cluster_id,

              window_from_height:
                from_height,

              window_to_height:
                resolved_to_height,

              profile_evidence:
                profile_result.fetch(
                  :evidence
                ),

              distribution_evidence:
                distribution_result.fetch(
                  :evidence
                ),

              provenance: {
                builder_version:
                  VERSION,

                analysis_kind:
                  Contract::ANALYSIS_KIND,

                shadow_mode:
                  Contract::SHADOW_MODE,

                profile_evidence_version:
                  ProfileEvidence::VERSION,

                distribution_evidence_version:
                  DirectDistributionEvidence::
                    VERSION,

                distribution_engine_version:
                  DirectDistributionEvidence::
                    ENGINE::
                    VERSION,

                score_version:
                  InfrastructureScore::VERSION,

                distribution_chunk_size:
                  distribution_chunk_size,

                distribution_window_blocks:
                  distribution_window_blocks,

                distribution_window: {
                  from_height:
                    from_height,

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
              profile:
                "certified",

              direct_distribution:
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
            stage:
              :orchestrator,
            reason:
              :calculation_failed,

            source_cluster_id:
              source_cluster_id,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            error_class:
              error.class.name,

            error_message:
              error.message,

            label_sync: {
              status: "skipped",
              reason: :shadow_mode
            }
          }
        end

        private

        attr_reader(
          :source_cluster_id,
          :distribution_window_blocks,
          :distribution_chunk_size,
          :requested_to_height,
          :profile_builder,
          :distribution_builder,
          :persister
        )

        def processed_height
          BlockBufferModel
            .where(status: "processed")
            .maximum(:height)
            .to_i
        end

        def resolve_chunk_size(
          requested_chunk_size
        )
          value =
            requested_chunk_size ||
            ENV.fetch(
              "ACTOR_BEHAVIOR_HEAVY_SERVICE_CHUNK_SIZE",
              DEFAULT_DISTRIBUTION_CHUNK_SIZE.to_s
            )

          value
            .to_i
            .clamp(
              10,
              500
            )
        end

        def certified?(result)
          result[:ok] &&
            result[:status] ==
              "certified"
        end

        def propagate(
          stage:,
          result:
        )
          result.merge(
            stage:
              stage,

            source_cluster_id:
              source_cluster_id,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            label_sync: {
              status: "skipped",
              reason: :shadow_mode
            }
          )
        end

        def deferred(
          stage:,
          reason:
        )
          {
            ok: true,
            status: "deferred",
            stage:
              stage,
            reason:
              reason,

            source_cluster_id:
              source_cluster_id,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            label_sync: {
              status: "skipped",
              reason: :shadow_mode
            }
          }
        end
      end
    end
  end
end
