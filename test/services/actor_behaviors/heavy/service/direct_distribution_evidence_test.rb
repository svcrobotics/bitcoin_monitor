# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class DirectDistributionEvidenceTest <
        ActiveSupport::TestCase

        test "analyzes the service cluster directly" do
          received_arguments = nil

          engine_result = {
            ok: true,
            status: "certified",

            evidence: {
              analysis_version:
                "downstream_distribution_segmented_v1",

              cluster_id:
                34,

              window_from_height:
                900,

              window_to_height:
                1_000,

              spending_transactions:
                140,

              spending_blocks:
                75,

              distinct_external_addresses:
                820,

              distinct_external_clusters:
                210,

              top_destination_share_percent:
                "4.25"
            }
          }

          engine =
            lambda do |**arguments|
              received_arguments =
                arguments

              engine_result
            end

          result =
            DirectDistributionEvidence.call(
              cluster_id:
                34,

              from_height:
                900,

              to_height:
                1_000,

              chunk_size:
                50,

              engine:
                engine
            )

          assert_equal(
            true,
            result[:ok]
          )

          assert_equal(
            "certified",
            result[:status]
          )

          assert_equal(
            {
              cluster_id: 34,
              from_height: 900,
              to_height: 1_000,
              chunk_size: 50
            },
            received_arguments
          )

          evidence =
            result.fetch(
              :evidence
            )

          assert_equal(
            "service_direct_distribution_evidence_v1",
            evidence[:analysis_version]
          )

          assert_equal(
            "service_infrastructure",
            evidence[:analysis_kind]
          )

          assert_equal(
            "service_candidate",
            evidence[:cluster_role]
          )

          assert_equal(
            34,
            evidence[:cluster_id]
          )

          assert_equal(
            SegmentedDirectDistributionEvidence::
              VERSION,
            evidence[
              :distribution_engine_version
            ]
          )

          assert_equal(
            140,
            evidence.dig(
              :metrics,
              :spending_transactions
            )
          )

          assert_equal(
            210,
            evidence.dig(
              :metrics,
              :distinct_external_clusters
            )
          )
        end

        test "propagates a deferred engine result" do
          engine_result = {
            ok: true,
            status: "deferred",
            reason:
              :no_distribution_activity,
            evidence: {}
          }

          engine =
            lambda do |**_arguments|
              engine_result
            end

          result =
            DirectDistributionEvidence.call(
              cluster_id:
                34,

              from_height:
                900,

              to_height:
                1_000,

              engine:
                engine
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
            :no_distribution_activity,
            result[:reason]
          )

          assert_equal(
            :direct_distribution,
            result[:stage]
          )

          assert_equal(
            "service_infrastructure",
            result[:analysis_kind]
          )

          assert_equal(
            34,
            result[:service_cluster_id]
          )
        end

        test "rejects evidence produced for another cluster" do
          engine_result = {
            ok: true,
            status: "certified",

            evidence: {
              cluster_id:
                99
            }
          }

          engine =
            lambda do |**_arguments|
              engine_result
            end

          result =
            DirectDistributionEvidence.call(
              cluster_id:
                34,

              from_height:
                900,

              to_height:
                1_000,

              engine:
                engine
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
            :distribution_cluster_mismatch,
            result[:reason]
          )

          assert_equal(
            34,
            result[:service_cluster_id]
          )

          assert_equal(
            99,
            result[:observed_cluster_id]
          )

          assert_empty(
            result[:evidence]
          )
        end
      end
    end
  end
end
