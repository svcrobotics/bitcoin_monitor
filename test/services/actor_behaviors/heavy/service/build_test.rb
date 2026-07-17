# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class BuildTest <
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
                "service-build-profile-fingerprint",

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

        test "assembles the service pipeline directly on the candidate cluster" do
          received_profile = nil
          received_distribution = nil
          received_persistence = nil

          profile_builder =
            lambda do |actor_profile:|
              received_profile =
                actor_profile

              {
                ok: true,
                status: "certified",

                evidence: {
                  cluster_id:
                    actor_profile.cluster_id,

                  actor_profile_id:
                    actor_profile.id,

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
              }
            end

          distribution_builder =
            lambda do |**arguments|
              received_distribution =
                arguments

              {
                ok: true,
                status: "certified",

                evidence: {
                  cluster_id:
                    arguments.fetch(
                      :cluster_id
                    ),

                  metrics: {
                    spending_transactions:
                      428
                  }
                }
              }
            end

          persister =
            lambda do |**arguments|
              received_persistence =
                arguments

              {
                ok: true,
                status: "certified",
                decision: "confirmed",
                snapshot_id: 123,
                created: true,
                updated: false,
                unchanged: false,

                label_sync: {
                  status: "skipped",
                  reason: :shadow_mode
                }
              }
            end

          result =
            Build.call(
              source_cluster_id:
                @cluster.id,

              distribution_window_blocks:
                500,

              distribution_chunk_size:
                50,

              to_height:
                1_000,

              profile_builder:
                profile_builder,

              distribution_builder:
                distribution_builder,

              persister:
                persister
            )

          assert_equal(
            @profile,
            received_profile
          )

          assert_equal(
            {
              cluster_id:
                @cluster.id,

              from_height:
                501,

              to_height:
                1_000,

              chunk_size:
                50
            },
            received_distribution
          )

          assert_equal(
            @cluster.id,
            received_persistence[
              :source_cluster_id
            ]
          )

          assert_equal(
            501,
            received_persistence[
              :window_from_height
            ]
          )

          assert_equal(
            1_000,
            received_persistence[
              :window_to_height
            ]
          )

          assert_equal(
            "service_infrastructure",
            received_persistence.dig(
              :provenance,
              :analysis_kind
            )
          )

          assert_equal(
            true,
            received_persistence.dig(
              :provenance,
              :shadow_mode
            )
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
            "actor_behavior_heavy_service_build_v1",
            result[:builder_version]
          )

          assert_equal(
            {
              profile:
                "certified",

              direct_distribution:
                "certified",

              persistence:
                "certified"
            },
            result[:stages]
          )

          assert_equal(
            "skipped",
            result.dig(
              :label_sync,
              :status
            )
          )
        end

        test "propagates a deferred profile result" do
          distribution_called = false
          persistence_called = false

          profile_builder =
            lambda do |actor_profile:|
              assert_equal(
                @profile,
                actor_profile
              )

              {
                ok: true,
                status: "deferred",
                reason:
                  :profile_evidence_missing,
                evidence: {}
              }
            end

          distribution_builder =
            lambda do |**_arguments|
              distribution_called =
                true

              raise "distribution must not run"
            end

          persister =
            lambda do |**_arguments|
              persistence_called =
                true

              raise "persistence must not run"
            end

          result =
            Build.call(
              source_cluster_id:
                @cluster.id,

              to_height:
                1_000,

              profile_builder:
                profile_builder,

              distribution_builder:
                distribution_builder,

              persister:
                persister
            )

          assert_equal(
            "deferred",
            result[:status]
          )

          assert_equal(
            :profile,
            result[:stage]
          )

          assert_equal(
            :profile_evidence_missing,
            result[:reason]
          )

          assert_equal(
            false,
            distribution_called
          )

          assert_equal(
            false,
            persistence_called
          )

          assert_equal(
            :shadow_mode,
            result.dig(
              :label_sync,
              :reason
            )
          )
        end

        test "propagates a failed direct distribution result" do
          persistence_called = false

          profile_builder =
            lambda do |actor_profile:|
              {
                ok: true,
                status: "certified",

                evidence: {
                  cluster_id:
                    actor_profile.cluster_id,

                  actor_profile_id:
                    actor_profile.id
                }
              }
            end

          distribution_builder =
            lambda do |**_arguments|
              {
                ok: false,
                status: "failed",
                reason:
                  :distribution_query_failed,
                evidence: {}
              }
            end

          persister =
            lambda do |**_arguments|
              persistence_called =
                true

              raise "persistence must not run"
            end

          result =
            Build.call(
              source_cluster_id:
                @cluster.id,

              to_height:
                1_000,

              profile_builder:
                profile_builder,

              distribution_builder:
                distribution_builder,

              persister:
                persister
            )

          assert_equal(
            false,
            result[:ok]
          )

          assert_equal(
            "failed",
            result[:status]
          )

          assert_equal(
            :direct_distribution,
            result[:stage]
          )

          assert_equal(
            :distribution_query_failed,
            result[:reason]
          )

          assert_equal(
            false,
            persistence_called
          )
        end

        test "defers when the strict behavior snapshot is missing" do
          result =
            Build.call(
              source_cluster_id:
                @cluster.id + 999_999,

              to_height:
                1_000
            )

          assert_equal(
            true,
            result[:ok]
          )

          assert_equal(
            "deferred",
            result[:status]
          )

          assert_equal(
            :strict_snapshot,
            result[:stage]
          )

          assert_equal(
            :strict_behavior_snapshot_missing,
            result[:reason]
          )

          assert_equal(
            :shadow_mode,
            result.dig(
              :label_sync,
              :reason
            )
          )
        end
      end
    end
  end
end
