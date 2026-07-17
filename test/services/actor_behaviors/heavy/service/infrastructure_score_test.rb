# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class InfrastructureScoreTest <
        ActiveSupport::TestCase

        test "confirms a persistent broad service pattern in shadow mode" do
          result =
            InfrastructureScore.call(
              profile_evidence:
                strong_profile_evidence,

              distribution_evidence: {
                metrics:
                  strong_distribution_evidence
              }
            )

          assert_equal(
            "confirmed",
            result[:decision]
          )

          assert_equal(
            "shadow",
            result[:mode]
          )

          assert_equal(
            true,
            result.dig(
              :signals,
              :service_infrastructure_candidate
            )
          )

          assert_equal(
            false,
            result.dig(
              :signals,
              :service_identity_verified
            )
          )

          assert_equal(
            true,
            result.dig(
              :signals,
              :shadow_mode
            )
          )

          assert_operator(
            result.dig(
              :scores,
              :service_infrastructure_score
            ),
            :>=,
            75
          )

          assert_equal(
            85,
            result.dig(
              :scores,
              :classification_confidence
            )
          )

          assert_includes(
            result.dig(
              :evidence,
              :reasons
            ),
            "service_infrastructure_pattern_observed"
          )
        end

        test "does not confirm an active but narrow distribution" do
          distribution =
            strong_distribution_evidence.merge(
              distinct_external_addresses:
                20,

              distinct_external_clusters:
                5,

              top_destination_share_percent:
                "92"
            )

          result =
            InfrastructureScore.call(
              profile_evidence:
                strong_profile_evidence,

              distribution_evidence:
                distribution
            )

          assert_equal(
            "not_confirmed",
            result[:decision]
          )

          assert_equal(
            false,
            result.dig(
              :signals,
              :service_infrastructure_candidate
            )
          )

          assert_equal(
            false,
            result.dig(
              :signals,
              :broad_external_distribution_observed
            )
          )

          assert_includes(
            result.dig(
              :evidence,
              :reasons
            ),
            "broad_external_distribution_missing"
          )
        end

        test "returns insufficient evidence when a required metric is absent" do
          distribution =
            strong_distribution_evidence.dup

          distribution.delete(
            :distinct_external_clusters
          )

          result =
            InfrastructureScore.call(
              profile_evidence:
                strong_profile_evidence,

              distribution_evidence:
                distribution
            )

          assert_equal(
            "insufficient_evidence",
            result[:decision]
          )

          assert_equal(
            false,
            result.dig(
              :signals,
              :service_infrastructure_candidate
            )
          )

          assert_includes(
            result.dig(
              :evidence,
              :missing_evidence
            ),
            "distribution.distinct_external_clusters"
          )
        end

        test "ignores exchange classification fields" do
          profile_a =
            strong_profile_evidence.merge(
              exchange_infrastructure_candidate:
                true,

              exchange_score:
                100
            )

          profile_b =
            strong_profile_evidence.merge(
              exchange_infrastructure_candidate:
                false,

              exchange_score:
                0
            )

          result_a =
            InfrastructureScore.call(
              profile_evidence:
                profile_a,

              distribution_evidence:
                strong_distribution_evidence
            )

          result_b =
            InfrastructureScore.call(
              profile_evidence:
                profile_b,

              distribution_evidence:
                strong_distribution_evidence
            )

          assert_equal(
            result_a,
            result_b
          )
        end

        private

        def strong_profile_evidence
          {
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

        def strong_distribution_evidence
          {
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
        end
      end
    end
  end
end
