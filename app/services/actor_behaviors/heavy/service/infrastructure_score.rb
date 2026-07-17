# frozen_string_literal: true

require "bigdecimal"

module ActorBehaviors
  module Heavy
    module Service
      class InfrastructureScore
        VERSION =
          "service_infrastructure_score_shadow_v1"

        CANDIDATE_MIN_SCORE = 75
        CONFIDENCE_CAP = 85

        MINIMUM_ACTIVITY_SPAN_BLOCKS =
          1_000

        MINIMUM_SPENDING_TRANSACTIONS =
          20

        MINIMUM_SPENDING_BLOCKS =
          20

        MINIMUM_EXTERNAL_ADDRESSES =
          100

        MINIMUM_EXTERNAL_CLUSTERS =
          50

        PROFILE_REQUIRED_KEYS = %i[
          tx_count
          activity_span_blocks
          received_tx_count
          spending_tx_count
          bidirectional_activity_observed
        ].freeze

        DISTRIBUTION_REQUIRED_KEYS = %i[
          spending_transactions
          spending_blocks
          distinct_external_addresses
          distinct_external_clusters
          batch_transaction_percent
          top_destination_share_percent
          mixed_input_transactions
          missing_output_transactions
        ].freeze

        def self.call(
          profile_evidence:,
          distribution_evidence:
        )
          new(
            profile_evidence:
              profile_evidence,

            distribution_evidence:
              distribution_evidence
          ).call
        end

        def initialize(
          profile_evidence:,
          distribution_evidence:
        )
          @profile =
            profile_evidence
              .to_h
              .with_indifferent_access

          raw_distribution =
            distribution_evidence
              .to_h
              .with_indifferent_access

          @distribution =
            if raw_distribution.key?(
              :metrics
            )
              raw_distribution
                .fetch(:metrics)
                .to_h
                .with_indifferent_access
            else
              raw_distribution
            end
        end

        def call
          missing =
            missing_evidence

          if missing.any?
            return insufficient_result(
              missing
            )
          end

          continuity_score =
            operational_continuity_score

          breadth_score =
            external_distribution_breadth_score

          regularity_score =
            distribution_regularity_score

          total_score =
            (
              continuity_score * 0.35 +
              breadth_score * 0.40 +
              regularity_score * 0.25
            ).round.clamp(
              0,
              100
            )

          gates =
            hard_gates

          candidate =
            gates.values.all? &&
            total_score >=
              CANDIDATE_MIN_SCORE

          confidence =
            if candidate
              [
                total_score,
                CONFIDENCE_CAP
              ].min
            else
              0
            end

          {
            version:
              VERSION,

            mode:
              "shadow",

            decision:
              candidate ?
                "confirmed" :
                "not_confirmed",

            scores: {
              operational_continuity_score:
                continuity_score,

              external_distribution_breadth_score:
                breadth_score,

              distribution_regularity_score:
                regularity_score,

              service_infrastructure_score:
                total_score,

              classification_confidence:
                confidence
            },

            signals: {
              persistent_operation_observed:
                gates[
                  :persistent_operation_observed
                ],

              bidirectional_operation_observed:
                gates[
                  :bidirectional_operation_observed
                ],

              recurrent_distribution_observed:
                gates[
                  :recurrent_distribution_observed
                ],

              broad_external_distribution_observed:
                gates[
                  :broad_external_distribution_observed
                ],

              complete_output_evidence:
                gates[
                  :complete_output_evidence
                ],

              service_infrastructure_candidate:
                candidate,

              service_identity_verified:
                false,

              shadow_mode:
                true
            },

            evidence: {
              threshold_version:
                VERSION,

              thresholds:
                thresholds,

              hard_gates:
                gates,

              missing_evidence:
                [],

              reasons:
                reasons_for(
                  candidate:
                    candidate,

                  gates:
                    gates,

                  total_score:
                    total_score
                )
            }
          }
        end

        private

        attr_reader(
          :profile,
          :distribution
        )

        def missing_evidence
          missing = []

          PROFILE_REQUIRED_KEYS.each do |key|
            unless profile.key?(key)
              missing <<
                "profile.#{key}"
            end
          end

          DISTRIBUTION_REQUIRED_KEYS.each do |key|
            unless distribution.key?(key)
              missing <<
                "distribution.#{key}"
            end
          end

          missing
        end

        def operational_continuity_score
          score = 0

          tx_count =
            integer(
              profile[:tx_count]
            )

          score +=
            if tx_count >= 1_000
              25
            elsif tx_count >= 100
              15
            elsif tx_count >= 20
              5
            else
              0
            end

          activity_span =
            integer(
              profile[
                :activity_span_blocks
              ]
            )

          score +=
            if activity_span >= 10_000
              25
            elsif activity_span >= 1_000
              15
            elsif activity_span >= 144
              5
            else
              0
            end

          if truthy?(
            profile[
              :bidirectional_activity_observed
            ]
          )
            score += 20
          end

          received_transactions =
            integer(
              profile[
                :received_tx_count
              ]
            )

          score +=
            if received_transactions >= 100
              15
            elsif received_transactions >= 20
              8
            else
              0
            end

          spending_transactions =
            integer(
              profile[
                :spending_tx_count
              ]
            )

          score +=
            if spending_transactions >= 100
              15
            elsif spending_transactions >= 20
              8
            else
              0
            end

          score.clamp(
            0,
            100
          )
        end

        def external_distribution_breadth_score
          score = 0

          spending_transactions =
            integer(
              distribution[
                :spending_transactions
              ]
            )

          score +=
            if spending_transactions >= 100
              20
            elsif spending_transactions >= 20
              10
            else
              0
            end

          spending_blocks =
            integer(
              distribution[
                :spending_blocks
              ]
            )

          score +=
            if spending_blocks >= 100
              20
            elsif spending_blocks >= 20
              10
            else
              0
            end

          external_addresses =
            integer(
              distribution[
                :distinct_external_addresses
              ]
            )

          score +=
            if external_addresses >= 1_000
              25
            elsif external_addresses >= 100
              15
            elsif external_addresses >= 25
              5
            else
              0
            end

          external_clusters =
            integer(
              distribution[
                :distinct_external_clusters
              ]
            )

          score +=
            if external_clusters >= 200
              20
            elsif external_clusters >= 50
              12
            elsif external_clusters >= 10
              5
            else
              0
            end

          concentration =
            decimal(
              distribution[
                :top_destination_share_percent
              ]
            )

          score +=
            if concentration < 25
              15
            elsif concentration < 50
              10
            elsif concentration < 80
              5
            else
              0
            end

          score.clamp(
            0,
            100
          )
        end

        def distribution_regularity_score
          score = 0

          batch_percent =
            decimal(
              distribution[
                :batch_transaction_percent
              ]
            )

          score +=
            if batch_percent >= 50
              25
            elsif batch_percent >= 20
              15
            elsif batch_percent >= 5
              5
            else
              0
            end

          average_outputs =
            decimal(
              distribution[
                :average_outputs_per_transaction
              ]
            )

          score +=
            if average_outputs >= 10
              20
            elsif average_outputs >= 3
              10
            else
              0
            end

          median_outputs =
            decimal(
              distribution[
                :median_outputs_per_transaction
              ]
            )

          score +=
            if median_outputs >= 3
              15
            elsif median_outputs >= 2
              8
            else
              0
            end

          p90_outputs =
            decimal(
              distribution[
                :p90_outputs_per_transaction
              ]
            )

          score +=
            if p90_outputs >= 10
              15
            elsif p90_outputs >= 5
              8
            else
              0
            end

          if integer(
            distribution[
              :missing_output_transactions
            ]
          ).zero?
            score += 15
          end

          mixed_percent =
            mixed_input_percent

          score +=
            if mixed_percent <= 5
              10
            elsif mixed_percent <= 10
              5
            else
              0
            end

          score.clamp(
            0,
            100
          )
        end

        def hard_gates
          {
            persistent_operation_observed:
              integer(
                profile[
                  :activity_span_blocks
                ]
              ) >=
                MINIMUM_ACTIVITY_SPAN_BLOCKS,

            bidirectional_operation_observed:
              truthy?(
                profile[
                  :bidirectional_activity_observed
                ]
              ),

            recurrent_distribution_observed:
              integer(
                distribution[
                  :spending_transactions
                ]
              ) >=
                MINIMUM_SPENDING_TRANSACTIONS &&
              integer(
                distribution[
                  :spending_blocks
                ]
              ) >=
                MINIMUM_SPENDING_BLOCKS,

            broad_external_distribution_observed:
              integer(
                distribution[
                  :distinct_external_addresses
                ]
              ) >=
                MINIMUM_EXTERNAL_ADDRESSES &&
              integer(
                distribution[
                  :distinct_external_clusters
                ]
              ) >=
                MINIMUM_EXTERNAL_CLUSTERS,

            complete_output_evidence:
              integer(
                distribution[
                  :missing_output_transactions
                ]
              ).zero?
          }
        end

        def reasons_for(
          candidate:,
          gates:,
          total_score:
        )
          reasons = []

          unless gates[
            :persistent_operation_observed
          ]
            reasons <<
              "persistent_operation_missing"
          end

          unless gates[
            :bidirectional_operation_observed
          ]
            reasons <<
              "bidirectional_operation_missing"
          end

          unless gates[
            :recurrent_distribution_observed
          ]
            reasons <<
              "recurrent_distribution_missing"
          end

          unless gates[
            :broad_external_distribution_observed
          ]
            reasons <<
              "broad_external_distribution_missing"
          end

          unless gates[
            :complete_output_evidence
          ]
            reasons <<
              "incomplete_output_evidence"
          end

          if total_score <
             CANDIDATE_MIN_SCORE
            reasons <<
              "service_infrastructure_score_below_threshold"
          end

          if candidate
            reasons <<
              "service_infrastructure_pattern_observed"
          end

          reasons
        end

        def thresholds
          {
            candidate_min_score:
              CANDIDATE_MIN_SCORE,

            confidence_cap:
              CONFIDENCE_CAP,

            minimum_activity_span_blocks:
              MINIMUM_ACTIVITY_SPAN_BLOCKS,

            minimum_spending_transactions:
              MINIMUM_SPENDING_TRANSACTIONS,

            minimum_spending_blocks:
              MINIMUM_SPENDING_BLOCKS,

            minimum_external_addresses:
              MINIMUM_EXTERNAL_ADDRESSES,

            minimum_external_clusters:
              MINIMUM_EXTERNAL_CLUSTERS
          }
        end

        def mixed_input_percent
          spending_transactions =
            integer(
              distribution[
                :spending_transactions
              ]
            )

          return BigDecimal("100") unless
            spending_transactions.positive?

          mixed_transactions =
            integer(
              distribution[
                :mixed_input_transactions
              ]
            )

          (
            BigDecimal(
              mixed_transactions.to_s
            ) /
            BigDecimal(
              spending_transactions.to_s
            ) *
            100
          )
        end

        def insufficient_result(missing)
          {
            version:
              VERSION,

            mode:
              "shadow",

            decision:
              "insufficient_evidence",

            scores: {
              operational_continuity_score:
                0,

              external_distribution_breadth_score:
                0,

              distribution_regularity_score:
                0,

              service_infrastructure_score:
                0,

              classification_confidence:
                0
            },

            signals: {
              service_infrastructure_candidate:
                false,

              service_identity_verified:
                false,

              shadow_mode:
                true
            },

            evidence: {
              threshold_version:
                VERSION,

              thresholds:
                thresholds,

              hard_gates: {},

              missing_evidence:
                missing,

              reasons: [
                "required_evidence_missing"
              ]
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
        rescue ArgumentError, TypeError
          BigDecimal("0")
        end

        def truthy?(value)
          value == true ||
            value.to_s == "true"
        end
      end
    end
  end
end
