# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class OverviewSnapshotTest <
        ActiveSupport::TestCase

        test "reports only current service snapshots" do
          confirmed =
            create_service_case(
              decision:
                "confirmed",

              score:
                82,

              candidate:
                true,

              external_clusters:
                120
            )

          rejected =
            create_service_case(
              decision:
                "not_confirmed",

              score:
                64,

              candidate:
                false,

              external_clusters:
                32
            )

          create_exchange_case(
            cluster:
              confirmed.cluster,

            profile:
              confirmed.actor_profile,

            strict_snapshot:
              confirmed.actor_behavior_snapshot
          )

          result =
            OverviewSnapshot.call

          assert_equal(
            "active",
            result[:status]
          )

          assert_equal(
            2,
            result[:analyzed]
          )

          assert_equal(
            1,
            result[:confirmed]
          )

          assert_equal(
            1,
            result[:not_confirmed]
          )

          assert_equal(
            0,
            result[:insufficient_evidence]
          )

          assert_equal(
            0,
            result[:conflicting_evidence]
          )

          assert_equal(
            "service_infrastructure",
            result[:analysis_kind]
          )

          assert_equal(
            Contract::HEAVY_VERSION,
            result[:heavy_version]
          )

          assert_equal(
            true,
            result[:shadow_mode]
          )

          assert_equal(
            false,
            result[:labels_enabled]
          )

          assert_equal(
            0,
            result[:labels_published]
          )

          assert_equal(
            false,
            result[:automatic]
          )

          assert_equal(
            false,
            result[:scheduler_enabled]
          )

          assert_equal(
            [82, 64],
            result[:cases].map do |item|
              item[:score]
            end
          )

          assert_equal(
            [
              confirmed.cluster_id,
              rejected.cluster_id
            ],
            result[:cases].map do |item|
              item[:cluster_id]
            end
          )

          assert_equal(
            "source_first",
            result[:cases]
              .first[
                :scan_strategy
              ]
          )

          assert_equal(
            120,
            result[:cases]
              .first[
                :external_clusters
              ]
          )
        end

        private

        def create_service_case(
          decision:,
          score:,
          candidate:,
          external_clusters:
        )
          cluster =
            Cluster.create!

          profile =
            ActorProfile.create!(
              cluster:
                cluster,

              balance_btc:
                "20",

              total_received_btc:
                "1000",

              total_sent_btc:
                "980",

              net_btc:
                "20",

              tx_count:
                12_500,

              inflow_count:
                7_500,

              outflow_count:
                5_000,

              traits: {},
              metadata: {},

              last_computed_height:
                957_010,

              dirty:
                false,

              cluster_composition_version:
                cluster.composition_version
            )

          strict_snapshot =
            ActorBehaviorSnapshot.create!(
              cluster:
                cluster,

              actor_profile:
                profile,

              profile_version:
                "strict_v4_core_facts",

              profile_height:
                957_010,

              cluster_composition_version:
                cluster.composition_version,

              profile_fingerprint:
                "overview-profile-#{cluster.id}",

              behavior_version:
                ActorBehaviors::
                  StrictBuildFromProfile::
                  BEHAVIOR_VERSION,

              status:
                "certified",

              signals: {
                service_like_candidate_inputs:
                  true
              },

              scores: {
                service_score:
                  90
              },

              evidence: {},

              computed_at:
                Time.current
            )

          ActorBehaviorHeavySnapshot.create!(
            cluster:
              cluster,

            actor_profile:
              profile,

            actor_behavior_snapshot:
              strict_snapshot,

            downstream_cluster_id:
              nil,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            heavy_version:
              Contract::HEAVY_VERSION,

            status:
              "certified",

            source_profile_fingerprint:
              strict_snapshot.profile_fingerprint,

            source_profile_height:
              strict_snapshot.profile_height,

            source_cluster_composition_version:
              strict_snapshot
                .cluster_composition_version,

            source_behavior_version:
              strict_snapshot.behavior_version,

            window_from_height:
              956_511,

            window_to_height:
              957_010,

            signals: {
              service_infrastructure_candidate:
                candidate,

              service_identity_verified:
                false,

              shadow_mode:
                true
            },

            scores: {
              operational_continuity_score:
                90,

              external_distribution_breadth_score:
                80,

              distribution_regularity_score:
                40,

              service_infrastructure_score:
                score,

              classification_confidence:
                candidate ? 82 : 0
            },

            evidence: {
              profile: {
                address_count:
                  1_500,

                tx_count:
                  12_500,

                activity_span_blocks:
                  10_001
              },

              direct_distribution: {
                metrics: {
                  scan_strategy:
                    "source_first",

                  spending_transactions:
                    200,

                  spending_blocks:
                    150,

                  distinct_external_addresses:
                    500,

                  distinct_external_clusters:
                    external_clusters,

                  top_destination_cluster_id:
                    999,

                  top_destination_share_percent:
                    "20.5",

                  batch_transaction_percent:
                    "40",

                  average_outputs_per_transaction:
                    "4.5",

                  stage_durations_seconds: {
                    source_addresses:
                      0.1,

                    chunk_01_source_spends:
                      0.2,

                    chunk_01_all_input_stats:
                      0.7
                  }
                }
              },

              score_evidence: {
                version:
                  InfrastructureScore::VERSION,

                mode:
                  "shadow",

                decision:
                  decision,

                hard_gates: {
                  persistent_operation_observed:
                    true
                },

                reasons: [
                  decision == "confirmed" ?
                    "service_infrastructure_pattern_observed" :
                    "service_infrastructure_score_below_threshold"
                ]
              },

              provenance: {
                builder_version:
                  Build::VERSION
              }
            },

            evidence_fingerprint:
              "overview-service-#{cluster.id}",

            computed_at:
              Time.current
          )
        end

        def create_exchange_case(
          cluster:,
          profile:,
          strict_snapshot:
        )
          downstream =
            Cluster.create!

          ActorBehaviorHeavySnapshot.create!(
            cluster:
              cluster,

            actor_profile:
              profile,

            actor_behavior_snapshot:
              strict_snapshot,

            downstream_cluster:
              downstream,

            analysis_kind:
              "exchange_infrastructure",

            heavy_version:
              ActorBehaviors::Heavy::
                BuildFromEvidence::
                HEAVY_VERSION,

            status:
              "certified",

            source_profile_fingerprint:
              strict_snapshot.profile_fingerprint,

            source_profile_height:
              strict_snapshot.profile_height,

            source_cluster_composition_version:
              strict_snapshot
                .cluster_composition_version,

            source_behavior_version:
              strict_snapshot.behavior_version,

            window_from_height:
              956_511,

            window_to_height:
              957_010,

            signals: {},
            scores: {},
            evidence: {},

            evidence_fingerprint:
              "overview-exchange-#{cluster.id}",

            computed_at:
              Time.current
          )
        end
      end
    end
  end
end
