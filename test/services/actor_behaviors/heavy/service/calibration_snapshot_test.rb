# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class CalibrationSnapshotTest <
        ActiveSupport::TestCase

        Snapshot =
          Struct.new(
            :id,
            :cluster_id,
            :scores,
            :evidence,
            keyword_init: true
          )

        test "summarizes shadow calibration without changing decisions" do
          records = [
            build_snapshot(
              id: 1,
              cluster_id: 100,
              score: 73,
              decision: "not_confirmed",
              external_clusters: 74,
              top_share: "19.29",
              duration: 24.5,
              all_gates: true,
              reasons: [
                "service_infrastructure_score_below_threshold"
              ]
            ),

            build_snapshot(
              id: 2,
              cluster_id: 101,
              score: 67,
              decision: "not_confirmed",
              external_clusters: 57,
              top_share: "95.5",
              duration: 32.0,
              all_gates: true,
              reasons: [
                "service_infrastructure_score_below_threshold"
              ]
            ),

            build_snapshot(
              id: 3,
              cluster_id: 102,
              score: 66,
              decision: "not_confirmed",
              external_clusters: 39,
              top_share: "40.17",
              duration: 2.0,
              all_gates: false,
              reasons: [
                "broad_external_distribution_missing",
                "service_infrastructure_score_below_threshold"
              ]
            ),

            build_snapshot(
              id: 4,
              cluster_id: 103,
              score: 64,
              decision: "not_confirmed",
              external_clusters: 32,
              top_share: "19.7",
              duration: 21.7,
              all_gates: false,
              reasons: [
                "broad_external_distribution_missing",
                "service_infrastructure_score_below_threshold"
              ]
            )
          ]

          result =
            CalibrationSnapshot.call(
              records:
                records
            )

          assert_equal(
            "active",
            result[:status]
          )

          assert_equal(
            4,
            result[:analyzed]
          )

          assert_equal(
            {
              "not_confirmed" => 4
            },
            result[:decision_counts]
          )

          assert_equal(
            1,
            result[:near_threshold_count]
          )

          assert_equal(
            2,
            result[
              :all_hard_gates_passed_count
            ]
          )

          assert_equal(
            1,
            result[:high_concentration_count]
          )

          assert_equal(
            64.0,
            result.dig(
              :score_statistics,
              :minimum
            )
          )

          assert_equal(
            66.5,
            result.dig(
              :score_statistics,
              :median
            )
          )

          assert_equal(
            67.5,
            result.dig(
              :score_statistics,
              :average
            )
          )

          assert_equal(
            73.0,
            result.dig(
              :score_statistics,
              :maximum
            )
          )

          assert_equal(
            100,
            result.dig(
              :manual_review_cases,
              0,
              :cluster_id
            )
          )

          assert_equal(
            "collect_more_shadow_samples",
            result[:recommendation]
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
            false,
            result[:labels_enabled]
          )
        end

        private

        def build_snapshot(
          id:,
          cluster_id:,
          score:,
          decision:,
          external_clusters:,
          top_share:,
          duration:,
          all_gates:,
          reasons:
        )
          gates = {
            persistent_operation_observed:
              true,

            bidirectional_operation_observed:
              true,

            recurrent_distribution_observed:
              true,

            broad_external_distribution_observed:
              all_gates,

            complete_output_evidence:
              true
          }

          Snapshot.new(
            id:
              id,

            cluster_id:
              cluster_id,

            scores: {
              service_infrastructure_score:
                score,

              operational_continuity_score:
                90,

              external_distribution_breadth_score:
                70,

              distribution_regularity_score:
                30
            },

            evidence: {
              direct_distribution: {
                metrics: {
                  distinct_external_clusters:
                    external_clusters,

                  distinct_external_addresses:
                    200,

                  top_destination_share_percent:
                    top_share,

                  batch_transaction_percent:
                    "3",

                  average_outputs_per_transaction:
                    "2.5",

                  stage_durations_seconds: {
                    total:
                      duration
                  }
                }
              },

              score_evidence: {
                decision:
                  decision,

                hard_gates:
                  gates,

                reasons:
                  reasons
              }
            }
          )
        end
      end
    end
  end
end
