# frozen_string_literal: true

require "bigdecimal"

module ActorBehaviors
  module Heavy
    module Service
      class CalibrationSnapshot
        VERSION =
          "heavy_service_calibration_shadow_v1"

        DEFAULT_LIMIT = 500
        MAXIMUM_LIMIT = 1_000

        NEAR_THRESHOLD_MINIMUM = 70

        HIGH_CONCENTRATION_PERCENT =
          BigDecimal("90")

        def self.call(
          records: nil,
          limit: DEFAULT_LIMIT
        )
          new(
            records:
              records,

            limit:
              limit
          ).call
        end

        def initialize(
          records:,
          limit:
        )
          @provided_records =
            records

          @limit =
            limit.to_i.clamp(
              1,
              MAXIMUM_LIMIT
            )
        end

        def call
          cases =
            source_records.map do |snapshot|
              case_payload(
                snapshot
              )
            end

          scores =
            cases.map do |item|
              item.fetch(:score)
            end

          durations =
            cases.filter_map do |item|
              item[:measured_duration_seconds]
            end

          {
            status:
              cases.any? ?
                "active" :
                "empty",

            calibration_version:
              VERSION,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            heavy_version:
              Contract::HEAVY_VERSION,

            score_version:
              InfrastructureScore::VERSION,

            engine_version:
              DirectDistributionEvidence::
                ENGINE::
                VERSION,

            shadow_mode:
              true,

            automatic:
              false,

            scheduler_enabled:
              false,

            labels_enabled:
              false,

            analyzed:
              cases.length,

            decision_counts:
              frequency(
                cases.map do |item|
                  item[:decision]
                end
              ),

            reason_counts:
              frequency(
                cases.flat_map do |item|
                  item[:reasons]
                end
              ),

            failed_gate_counts:
              frequency(
                cases.flat_map do |item|
                  item[:failed_gates]
                end
              ),

            score_statistics:
              statistics(
                scores
              ),

            duration_statistics_seconds:
              statistics(
                durations
              ),

            near_threshold_count:
              cases.count do |item|
                item[:score] >=
                  NEAR_THRESHOLD_MINIMUM &&
                item[:score] <
                  InfrastructureScore::
                    CANDIDATE_MIN_SCORE
              end,

            all_hard_gates_passed_count:
              cases.count do |item|
                item[
                  :all_hard_gates_passed
                ]
              end,

            high_concentration_count:
              cases.count do |item|
                concentration =
                  item[
                    :top_destination_share_percent
                  ]

                concentration.present? &&
                  decimal(concentration) >=
                    HIGH_CONCENTRATION_PERCENT
              end,

            manual_review_cases:
              manual_review_cases(
                cases
              ),

            recommendation:
              cases.length < 20 ?
                "collect_more_shadow_samples" :
                "review_shadow_calibration",

            generated_at:
              Time.current
          }
        rescue StandardError => error
          {
            status:
              "unavailable",

            calibration_version:
              VERSION,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            shadow_mode:
              true,

            automatic:
              false,

            scheduler_enabled:
              false,

            labels_enabled:
              false,

            analyzed:
              0,

            error_class:
              error.class.name,

            error_message:
              error.message,

            generated_at:
              Time.current
          }
        end

        private

        attr_reader(
          :provided_records,
          :limit
        )

        def source_records
          return Array(
            provided_records
          ).first(limit) if
            provided_records

          ActorBehaviorHeavySnapshot
            .where(
              status:
                "certified",

              analysis_kind:
                Contract::ANALYSIS_KIND,

              heavy_version:
                Contract::HEAVY_VERSION
            )
            .order(
              updated_at:
                :desc
            )
            .limit(limit)
            .to_a
        end

        def case_payload(snapshot)
          scores =
            snapshot
              .scores
              .to_h
              .deep_stringify_keys

          evidence =
            snapshot
              .evidence
              .to_h
              .deep_stringify_keys

          score_evidence =
            evidence
              .fetch(
                "score_evidence",
                {}
              )
              .to_h
              .stringify_keys

          distribution =
            evidence
              .dig(
                "direct_distribution",
                "metrics"
              )
              .to_h
              .stringify_keys

          hard_gates =
            score_evidence
              .fetch(
                "hard_gates",
                {}
              )
              .to_h
              .stringify_keys

          failed_gates =
            hard_gates.filter_map do |name, passed|
              name unless passed == true
            end

          durations =
            distribution
              .fetch(
                "stage_durations_seconds",
                {}
              )
              .to_h

          {
            snapshot_id:
              snapshot.id,

            cluster_id:
              snapshot.cluster_id,

            decision:
              score_evidence[
                "decision"
              ].presence ||
              "unknown",

            score:
              scores[
                "service_infrastructure_score"
              ].to_i,

            continuity_score:
              scores[
                "operational_continuity_score"
              ].to_i,

            breadth_score:
              scores[
                "external_distribution_breadth_score"
              ].to_i,

            regularity_score:
              scores[
                "distribution_regularity_score"
              ].to_i,

            external_clusters:
              distribution[
                "distinct_external_clusters"
              ].to_i,

            external_addresses:
              distribution[
                "distinct_external_addresses"
              ].to_i,

            top_destination_share_percent:
              decimal_or_nil(
                distribution[
                  "top_destination_share_percent"
                ]
              ),

            batch_transaction_percent:
              decimal_or_nil(
                distribution[
                  "batch_transaction_percent"
                ]
              ),

            average_outputs_per_transaction:
              decimal_or_nil(
                distribution[
                  "average_outputs_per_transaction"
                ]
              ),

            all_hard_gates_passed:
              hard_gates.any? &&
              hard_gates.values.all? do |passed|
                passed == true
              end,

            failed_gates:
              failed_gates,

            reasons:
              Array(
                score_evidence[
                  "reasons"
                ]
              ),

            measured_duration_seconds:
              durations.any? ?
                durations
                  .values
                  .sum(&:to_f)
                  .round(3) :
                nil
          }
        end

        def manual_review_cases(cases)
          cases
            .sort_by do |item|
              distance =
                (
                  InfrastructureScore::
                    CANDIDATE_MIN_SCORE -
                  item[:score]
                ).abs

              [
                distance,
                -item[:score],
                item[:cluster_id]
              ]
            end
            .first(20)
        end

        def frequency(values)
          values
            .compact
            .each_with_object(
              Hash.new(0)
            ) do |value, result|
              result[value.to_s] += 1
            end
            .sort_by do |key, count|
              [
                -count,
                key
              ]
            end
            .to_h
        end

        def statistics(values)
          numeric =
            values
              .compact
              .map(&:to_f)
              .sort

          return {
            count: 0,
            minimum: nil,
            median: nil,
            average: nil,
            p90: nil,
            maximum: nil
          } if numeric.empty?

          {
            count:
              numeric.length,

            minimum:
              numeric.first.round(3),

            median:
              median(numeric).round(3),

            average:
              (
                numeric.sum /
                numeric.length
              ).round(3),

            p90:
              percentile(
                numeric,
                90
              ).round(3),

            maximum:
              numeric.last.round(3)
          }
        end

        def median(values)
          middle =
            values.length / 2

          if values.length.odd?
            values[middle]
          else
            (
              values[middle - 1] +
              values[middle]
            ) / 2.0
          end
        end

        def percentile(
          values,
          percentage
        )
          rank =
            (
              percentage.to_f /
              100 *
              values.length
            ).ceil

          values[
            [
              rank - 1,
              0
            ].max
          ]
        end

        def decimal_or_nil(value)
          return nil if value.blank?

          decimal(value).to_f
        rescue ArgumentError, TypeError
          nil
        end

        def decimal(value)
          BigDecimal(
            value.to_s
          )
        end
      end
    end
  end
end
