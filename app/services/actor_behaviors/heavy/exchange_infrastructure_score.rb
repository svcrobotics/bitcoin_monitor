# frozen_string_literal: true

require "bigdecimal"

module ActorBehaviors
  module Heavy
    class ExchangeInfrastructureScore
      VERSION =
        "exchange_infrastructure_score_v2"

      CANDIDATE_MIN_SCORE = 80
      IDENTITY_CONFIDENCE_CAP = 90

      SWEEP_PASS_SCORE = 70

      MINIMUM_SWEEP_TOP_DESTINATION_PERCENT =
        BigDecimal("80")

      def self.call(
        deposit_evidence:,
        sweep_evidence:,
        distribution_evidence:
      )
        new(
          deposit_evidence:
            deposit_evidence,

          sweep_evidence:
            sweep_evidence,

          distribution_evidence:
            distribution_evidence
        ).call
      end

      def initialize(
        deposit_evidence:,
        sweep_evidence:,
        distribution_evidence:
      )
        @deposit =
          deposit_evidence
            .to_h
            .with_indifferent_access

        @sweep =
          sweep_evidence
            .to_h
            .with_indifferent_access

        @distribution =
          distribution_evidence
            .to_h
            .with_indifferent_access
      end

      def call
        deposit_score =
          deposit_collection_score

        sweep_concentrated =
          sweep_top_destination_concentrated?

        sweep_score =
          sweep_relation_score(
            concentrated:
              sweep_concentrated
          )

        sweep_observed =
          sweep_concentrated &&
          sweep_score >=
            SWEEP_PASS_SCORE

        distribution_score =
          downstream_distribution_score

        infrastructure_score =
          (
            deposit_score * 0.30 +
            sweep_score * 0.25 +
            distribution_score * 0.45
          ).round.clamp(0, 100)

        candidate =
          deposit_score >= 70 &&
          sweep_observed &&
          distribution_score >= 80 &&
          infrastructure_score >=
            CANDIDATE_MIN_SCORE

        confidence =
          if candidate
            [
              infrastructure_score,
              IDENTITY_CONFIDENCE_CAP
            ].min
          else
            0
          end

        {
          version:
            VERSION,

          scores: {
            deposit_collection_score:
              deposit_score,

            sweep_relation_score:
              sweep_score,

            downstream_distribution_score:
              distribution_score,

            exchange_infrastructure_score:
              infrastructure_score,

            classification_confidence:
              confidence
          },

          signals: {
            collection_consolidation_observed:
              deposit_score >= 70,

            recurrent_sweep_to_active_wallet:
              sweep_observed,

            broad_batch_distribution:
              distribution_score >= 80,

            exchange_infrastructure_candidate:
              candidate,

            exchange_identity_verified:
              false
          },

          evidence: {
            thresholds:
              thresholds,

            hard_gates: {
              sweep_top_destination_concentrated:
                sweep_concentrated
            },

            reasons:
              reasons_for(
                deposit_score:
                  deposit_score,

                sweep_observed:
                  sweep_observed,

                sweep_concentrated:
                  sweep_concentrated,

                distribution_score:
                  distribution_score,

                candidate:
                  candidate
              )
          }
        }
      end

      private

      attr_reader(
        :deposit,
        :sweep,
        :distribution
      )

      def deposit_collection_score
        score = 0

        score += 25 if integer(
          deposit[:address_count]
        ) >= 1_000

        score += 20 if integer(
          deposit[:inflow_count]
        ) >= 100

        inflows =
          integer(
            deposit[:inflow_count]
          )

        outflows =
          integer(
            deposit[:outflow_count]
          )

        if outflows.positive? &&
           inflows.fdiv(outflows) >= 20
          score += 15
        end

        received =
          decimal(
            deposit[:total_received_btc]
          )

        sent =
          decimal(
            deposit[:total_sent_btc]
          )

        balance =
          decimal(
            deposit[:balance_btc]
          ).abs

        if received.positive? &&
           balance / received <=
             BigDecimal("0.01")
          score += 20
        end

        if received.positive? &&
           sent / received >=
             BigDecimal("0.95")
          score += 20
        end

        score.clamp(0, 100)
      end

      def sweep_relation_score(
        concentrated:
      )
        score = 0

        score += 30 if concentrated

        score += 20 if integer(
          sweep[
            :consolidation_transactions
          ]
        ) >= 3

        score += 15 if integer(
          sweep[
            :consolidation_blocks
          ]
        ) >= 3

        score += 20 if integer(
          sweep[
            :destination_spending_transactions
          ]
        ) >= 20

        score += 15 if integer(
          sweep[
            :destination_spending_blocks
          ]
        ) >= 20

        score =
          score.clamp(
            0,
            100
          )

        return score if concentrated

        [
          score,
          SWEEP_PASS_SCORE - 1
        ].min
      end

      def sweep_top_destination_concentrated?
        decimal(
          sweep[
            :top_destination_share_percent
          ]
        ) >=
          MINIMUM_SWEEP_TOP_DESTINATION_PERCENT
      end

      def downstream_distribution_score
        score = 0

        spending_transactions =
          integer(
            distribution[
              :spending_transactions
            ]
          )

        score += 20 if
          spending_transactions >= 20

        score += 15 if integer(
          distribution[
            :spending_blocks
          ]
        ) >= 20

        score += 20 if decimal(
          distribution[
            :batch_transaction_percent
          ]
        ) >= 20

        score += 20 if integer(
          distribution[
            :distinct_external_addresses
          ]
        ) >= 100

        score += 15 if integer(
          distribution[
            :distinct_external_clusters
          ]
        ) >= 50

        score += 10 if decimal(
          distribution[
            :top_destination_share_percent
          ]
        ) < 80

        if integer(
          distribution[
            :missing_output_transactions
          ]
        ).positive?
          score -= 20
        end

        mixed_inputs =
          integer(
            distribution[
              :mixed_input_transactions
            ]
          )

        if spending_transactions.positive? &&
           mixed_inputs.fdiv(
             spending_transactions
           ) > 0.05
          score -= 10
        end

        score.clamp(0, 100)
      end

      def reasons_for(
        deposit_score:,
        sweep_observed:,
        sweep_concentrated:,
        distribution_score:,
        candidate:
      )
        reasons = []

        if deposit_score >= 70
          reasons <<
            "deposit_collection_pattern_observed"
        end

        if sweep_observed
          reasons <<
            "recurrent_sweep_to_active_wallet_observed"
        elsif !sweep_concentrated
          reasons <<
            "sweep_top_destination_concentration_missing"
        else
          reasons <<
            "sweep_destination_activity_insufficient"
        end

        if distribution_score >= 80
          reasons <<
            "broad_batch_distribution_observed"
        end

        if candidate
          reasons <<
            "exchange_infrastructure_candidate_inputs_satisfied"
        end

        reasons <<
          "identity_not_verified_on_chain"

        reasons
      end

      def thresholds
        {
          deposit_collection: {
            address_count: 1_000,
            inflow_count: 100,
            inflow_outflow_ratio: 20,
            maximum_balance_received_ratio: "0.01",
            minimum_sent_received_ratio: "0.95"
          },

          sweep_relation: {
            minimum_top_destination_percent: 80,
            minimum_transactions: 3,
            minimum_blocks: 3,
            minimum_destination_spending_transactions: 20,
            minimum_destination_spending_blocks: 20
          },

          distribution: {
            minimum_spending_transactions: 20,
            minimum_spending_blocks: 20,
            minimum_batch_percent: 20,
            minimum_external_addresses: 100,
            minimum_external_clusters: 50,
            maximum_top_destination_percent: 80
          },

          classification: {
            minimum_score:
              CANDIDATE_MIN_SCORE,

            identity_confidence_cap:
              IDENTITY_CONFIDENCE_CAP
          }
        }
      end

      def integer(value)
        value.to_i
      end

      def decimal(value)
        BigDecimal(
          value.to_s.presence || "0"
        )
      rescue ArgumentError
        BigDecimal("0")
      end
    end
  end
end
