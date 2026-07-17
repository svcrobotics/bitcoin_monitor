# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    class ExchangeInfrastructureScoreTest <
      ActiveSupport::TestCase

      test "certifies a complete collection sweep distribution chain" do
        result =
          ExchangeInfrastructureScore.call(
            deposit_evidence: {
              address_count: 1_484,
              inflow_count: 1_505,
              outflow_count: 15,
              balance_btc: "0.00131007",
              total_received_btc: "0.61803407",
              total_sent_btc: "0.616724"
            },

            sweep_evidence: {
              consolidation_transactions: 15,
              consolidation_blocks: 15,
              top_destination_share_percent: "100",
              destination_spending_transactions: 2_248,
              destination_spending_blocks: 1_435
            },

            distribution_evidence: {
              spending_transactions: 428,
              spending_blocks: 264,
              mixed_input_transactions: 2,
              missing_output_transactions: 0,
              batch_transaction_percent: "84.58",
              distinct_external_addresses: 2_449,
              distinct_external_clusters: 285,
              top_destination_share_percent: "30.86"
            }
          )

        assert_equal(
          true,
          result.dig(
            :signals,
            :exchange_infrastructure_candidate
          )
        )

        assert_equal(
          true,
          result.dig(
            :signals,
            :broad_batch_distribution
          )
        )

        assert_equal(
          false,
          result.dig(
            :signals,
            :exchange_identity_verified
          )
        )

        assert_equal(
          90,
          result.dig(
            :scores,
            :classification_confidence
          )
        )
      end

      test "does not certify an active but diffuse sweep" do
        result =
          ExchangeInfrastructureScore.call(
            deposit_evidence: {
              address_count: 3_000,
              inflow_count: 5_000,
              outflow_count: 100,
              balance_btc: "0",
              total_received_btc: "250",
              total_sent_btc: "250"
            },

            sweep_evidence: {
              consolidation_transactions: 462,
              consolidation_blocks: 400,

              top_destination_share_percent:
                "43.41",

              destination_spending_transactions:
                158,

              destination_spending_blocks:
                132
            },

            distribution_evidence: {
              spending_transactions: 158,
              spending_blocks: 132,
              mixed_input_transactions: 0,
              missing_output_transactions: 0,

              batch_transaction_percent:
                "56.96",

              distinct_external_addresses:
                599,

              distinct_external_clusters:
                224,

              top_destination_share_percent:
                "9.81"
            }
          )

        assert_equal(
          69,
          result.dig(
            :scores,
            :sweep_relation_score
          )
        )

        assert_equal(
          false,
          result.dig(
            :signals,
            :recurrent_sweep_to_active_wallet
          )
        )

        assert_equal(
          false,
          result.dig(
            :signals,
            :exchange_infrastructure_candidate
          )
        )

        assert_equal(
          0,
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

          "sweep_top_destination_concentration_missing"
        )
      end

      test "does not certify a concentrated wallet with insufficient history" do
        result =
          ExchangeInfrastructureScore.call(
            deposit_evidence: {
              address_count: 1_200,
              inflow_count: 1_100,
              outflow_count: 1,
              balance_btc: "0",
              total_received_btc: "1",
              total_sent_btc: "1"
            },

            sweep_evidence: {
              consolidation_transactions: 1,
              consolidation_blocks: 1,
              top_destination_share_percent: "100",
              destination_spending_transactions: 1,
              destination_spending_blocks: 1
            },

            distribution_evidence: {
              spending_transactions: 1,
              spending_blocks: 1,
              mixed_input_transactions: 0,
              missing_output_transactions: 0,
              batch_transaction_percent: "0",
              distinct_external_addresses: 1,
              distinct_external_clusters: 1,
              top_destination_share_percent: "100"
            }
          )

        assert_equal(
          false,
          result.dig(
            :signals,
            :exchange_infrastructure_candidate
          )
        )

        assert_operator(
          result.dig(
            :scores,
            :exchange_infrastructure_score
          ),
          :<,
          80
        )
      end
    end
  end
end
