# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class BuildFromEvidenceTest <
        ActiveSupport::TestCase

        setup do
          @cluster =
            Cluster.create!

          @profile =
            ActorProfile.create!(
              cluster:
                @cluster,

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
                956_900,

              dirty:
                false,

              cluster_composition_version:
                @cluster.composition_version
            )

          @strict_snapshot =
            ActorBehaviorSnapshot.create!(
              cluster:
                @cluster,

              actor_profile:
                @profile,

              profile_version:
                "strict_v4_core_facts",

              profile_height:
                956_900,

              cluster_composition_version:
                @cluster.composition_version,

              profile_fingerprint:
                "service-profile-fingerprint-1",

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
        end

        test "creates an independent service snapshot" do
          result =
            build_service_snapshot

          assert_equal(
            true,
            result[:ok]
          )

          assert_equal(
            "certified",
            result[:status]
          )

          assert_equal(
            "confirmed",
            result[:decision]
          )

          assert_equal(
            true,
            result[:created]
          )

          assert_equal(
            "skipped",
            result.dig(
              :label_sync,
              :status
            )
          )

          assert_equal(
            :shadow_mode,
            result.dig(
              :label_sync,
              :reason
            )
          )

          snapshot =
            ActorBehaviorHeavySnapshot.find(
              result.fetch(:snapshot_id)
            )

          assert_equal(
            @cluster.id,
            snapshot.cluster_id
          )

          assert_equal(
            "service_infrastructure",
            snapshot.analysis_kind
          )

          assert_nil(
            snapshot.downstream_cluster_id
          )

          assert_equal(
            Contract::HEAVY_VERSION,
            snapshot.heavy_version
          )

          assert_equal(
            "confirmed",
            snapshot.evidence.dig(
              "score_evidence",
              "decision"
            )
          )

          assert_equal(
            true,
            snapshot.signals[
              "service_infrastructure_candidate"
            ]
          )

          assert_equal(
            false,
            snapshot.signals[
              "service_identity_verified"
            ]
          )
        end

        test "is idempotent for identical evidence" do
          first =
            build_service_snapshot

          second =
            build_service_snapshot

          assert_equal(
            true,
            first[:created]
          )

          assert_equal(
            true,
            second[:unchanged]
          )

          assert_equal(
            false,
            second[:created]
          )

          assert_equal(
            false,
            second[:updated]
          )

          assert_equal(
            first[:snapshot_id],
            second[:snapshot_id]
          )

          assert_equal(
            1,
            ActorBehaviorHeavySnapshot.where(
              cluster_id:
                @cluster.id,

              analysis_kind:
                Contract::ANALYSIS_KIND
            ).count
          )
        end

        test "coexists with an exchange snapshot" do
          downstream_cluster =
            Cluster.create!

          exchange_snapshot =
            ActorBehaviorHeavySnapshot.create!(
              cluster:
                @cluster,

              actor_profile:
                @profile,

              actor_behavior_snapshot:
                @strict_snapshot,

              downstream_cluster:
                downstream_cluster,

              analysis_kind:
                "exchange_infrastructure",

              heavy_version:
                ActorBehaviors::Heavy::
                  BuildFromEvidence::
                  HEAVY_VERSION,

              status:
                "certified",

              source_profile_fingerprint:
                @strict_snapshot.profile_fingerprint,

              source_profile_height:
                @strict_snapshot.profile_height,

              source_cluster_composition_version:
                @strict_snapshot
                  .cluster_composition_version,

              source_behavior_version:
                @strict_snapshot.behavior_version,

              window_from_height:
                956_401,

              window_to_height:
                956_900,

              signals: {},
              scores: {},
              evidence: {},

              evidence_fingerprint:
                "exchange-fingerprint",

              computed_at:
                Time.current
            )

          result =
            build_service_snapshot

          assert_equal(
            true,
            result[:created]
          )

          assert_equal(
            2,
            ActorBehaviorHeavySnapshot.where(
              cluster_id:
                @cluster.id
            ).count
          )

          assert_equal(
            "exchange-fingerprint",
            exchange_snapshot.reload
              .evidence_fingerprint
          )

          assert_equal(
            "exchange_infrastructure",
            exchange_snapshot.analysis_kind
          )

          service_snapshot =
            ActorBehaviorHeavySnapshot.find(
              result.fetch(:snapshot_id)
            )

          assert_equal(
            "service_infrastructure",
            service_snapshot.analysis_kind
          )
        end

        test "defers evidence for another cluster" do
          evidence =
            profile_evidence.merge(
              cluster_id:
                @cluster.id + 1
            )

          result =
            BuildFromEvidence.call(
              source_cluster_id:
                @cluster.id,

              window_from_height:
                956_401,

              window_to_height:
                956_900,

              profile_evidence:
                evidence,

              distribution_evidence:
                distribution_evidence,

              provenance:
                provenance
            )

          assert_equal(
            "deferred",
            result[:status]
          )

          assert_equal(
            :profile_cluster_mismatch,
            result[:reason]
          )

          assert_equal(
            0,
            ActorBehaviorHeavySnapshot.where(
              analysis_kind:
                Contract::ANALYSIS_KIND
            ).count
          )
        end

        private

        def build_service_snapshot
          BuildFromEvidence.call(
            source_cluster_id:
              @cluster.id,

            window_from_height:
              956_401,

            window_to_height:
              956_900,

            profile_evidence:
              profile_evidence,

            distribution_evidence:
              distribution_evidence,

            provenance:
              provenance
          )
        end

        def profile_evidence
          {
            analysis_version:
              ProfileEvidence::VERSION,

            cluster_id:
              @cluster.id,

            actor_profile_id:
              @profile.id,

            tx_count:
              12_500,

            activity_span_blocks:
              10_001,

            received_tx_count:
              7_500,

            spending_tx_count:
              5_000,

            bidirectional_activity_observed:
              true
          }
        end

        def distribution_evidence
          {
            analysis_version:
              DirectDistributionEvidence::VERSION,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            cluster_role:
              "service_candidate",

            cluster_id:
              @cluster.id,

            window_from_height:
              956_401,

            window_to_height:
              956_900,

            metrics: {
              spending_transactions:
                428,

              spending_blocks:
                264,

              mixed_input_transactions:
                2,

              missing_output_transactions:
                0,

              average_outputs_per_transaction:
                "6.5",

              median_outputs_per_transaction:
                "4",

              p90_outputs_per_transaction:
                "12",

              batch_transaction_percent:
                "84.58",

              distinct_external_addresses:
                2_449,

              distinct_external_clusters:
                285,

              top_destination_share_percent:
                "30.86"
            }
          }
        end

        def provenance
          {
            builder_version:
              "service_build_test_v1",

            source_fact_tables: %w[
              actor_profiles
              addresses
              cluster_inputs
              utxo_outputs
            ]
          }
        end
      end
    end
  end
end
