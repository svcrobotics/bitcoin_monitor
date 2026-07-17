# frozen_string_literal: true

require "bigdecimal"

module ActorBehaviors
  module Heavy
    module Service
      class OverviewSnapshot
        DISPLAY_LIMIT = 50

        DECISIONS = %w[
          confirmed
          not_confirmed
          insufficient_evidence
          conflicting_evidence
        ].freeze

        def self.call(
          limit: DISPLAY_LIMIT
        )
          new(
            limit:
              limit
          ).call
        end

        def initialize(limit:)
          @limit =
            limit.to_i.clamp(
              1,
              DISPLAY_LIMIT
            )
        end

        def call
          scope =
            current_scope

          counts =
            DECISIONS.to_h do |decision|
              [
                decision,
                decision_scope(
                  scope,
                  decision
                ).count
              ]
            end

          records =
            scope
              .order(
                Arel.sql(
                  "COALESCE(" \
                  "(scores ->> " \
                  "'service_infrastructure_score')" \
                  "::integer, 0" \
                  ") DESC"
                ),
                updated_at: :desc
              )
              .limit(limit)
              .to_a

          {
            status:
              scope.exists? ?
                "active" :
                "empty",

            analyzed:
              scope.count,

            confirmed:
              counts.fetch(
                "confirmed"
              ),

            not_confirmed:
              counts.fetch(
                "not_confirmed"
              ),

            insufficient_evidence:
              counts.fetch(
                "insufficient_evidence"
              ),

            conflicting_evidence:
              counts.fetch(
                "conflicting_evidence"
              ),

            analysis_kind:
              Contract::ANALYSIS_KIND,

            heavy_version:
              Contract::HEAVY_VERSION,

            builder_version:
              Build::VERSION,

            score_version:
              InfrastructureScore::VERSION,

            distribution_engine_version:
              DirectDistributionEvidence::
                ENGINE::
                VERSION,

            scan_strategy:
              DirectDistributionEvidence::
                ENGINE::
                SCAN_STRATEGY,

            shadow_mode:
              Contract::SHADOW_MODE,

            labels_enabled:
              false,

            labels_published:
              0,

            automatic:
              false,

            scheduler_enabled:
              false,

            cases:
              records.map do |snapshot|
                case_payload(
                  snapshot
                )
              end,

            generated_at:
              Time.current
          }
        rescue StandardError => error
          {
            status: "unavailable",

            analyzed: 0,
            confirmed: 0,
            not_confirmed: 0,
            insufficient_evidence: 0,
            conflicting_evidence: 0,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            shadow_mode:
              true,

            labels_enabled:
              false,

            labels_published:
              0,

            cases: [],

            error_class:
              error.class.name,

            error_message:
              error.message,

            generated_at:
              Time.current
          }
        end

        private

        attr_reader :limit

        def current_scope
          ActorBehaviorHeavySnapshot.where(
            status:
              "certified",

            analysis_kind:
              Contract::ANALYSIS_KIND,

            heavy_version:
              Contract::HEAVY_VERSION
          )
        end

        def decision_scope(
          scope,
          decision
        )
          scope.where(
            "evidence #>> " \
            "'{score_evidence,decision}' = ?",
            decision
          )
        end

        def case_payload(snapshot)
          scores =
            snapshot
              .scores
              .to_h
              .stringify_keys

          signals =
            snapshot
              .signals
              .to_h
              .stringify_keys

          evidence =
            snapshot
              .evidence
              .to_h
              .stringify_keys

          profile =
            evidence
              .fetch(
                "profile",
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

          score_evidence =
            evidence
              .fetch(
                "score_evidence",
                {}
              )
              .to_h
              .stringify_keys

          stage_durations =
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

            candidate:
              signals[
                "service_infrastructure_candidate"
              ] == true,

            identity_verified:
              signals[
                "service_identity_verified"
              ] == true,

            score:
              scores[
                "service_infrastructure_score"
              ].to_i,

            confidence:
              scores[
                "classification_confidence"
              ].to_i,

            operational_continuity_score:
              scores[
                "operational_continuity_score"
              ].to_i,

            external_distribution_breadth_score:
              scores[
                "external_distribution_breadth_score"
              ].to_i,

            distribution_regularity_score:
              scores[
                "distribution_regularity_score"
              ].to_i,

            address_count:
              profile[
                "address_count"
              ].to_i,

            tx_count:
              profile[
                "tx_count"
              ].to_i,

            activity_span_blocks:
              profile[
                "activity_span_blocks"
              ].to_i,

            spending_transactions:
              distribution[
                "spending_transactions"
              ].to_i,

            spending_blocks:
              distribution[
                "spending_blocks"
              ].to_i,

            external_addresses:
              distribution[
                "distinct_external_addresses"
              ].to_i,

            external_clusters:
              distribution[
                "distinct_external_clusters"
              ].to_i,

            top_destination_cluster_id:
              distribution[
                "top_destination_cluster_id"
              ],

            top_destination_share_percent:
              decimal(
                distribution[
                  "top_destination_share_percent"
                ]
              ),

            batch_transaction_percent:
              decimal(
                distribution[
                  "batch_transaction_percent"
                ]
              ),

            average_outputs_per_transaction:
              decimal(
                distribution[
                  "average_outputs_per_transaction"
                ]
              ),

            scan_strategy:
              distribution[
                "scan_strategy"
              ],

            measured_duration_seconds:
              stage_durations
                .values
                .sum(&:to_f)
                .round(3),

            hard_gates:
              score_evidence
                .fetch(
                  "hard_gates",
                  {}
                ),

            reasons:
              Array(
                score_evidence[
                  "reasons"
                ]
              ),

            window_from_height:
              snapshot.window_from_height,

            window_to_height:
              snapshot.window_to_height,

            heavy_version:
              snapshot.heavy_version,

            builder_version:
              evidence.dig(
                "provenance",
                "builder_version"
              ),

            score_version:
              score_evidence[
                "version"
              ],

            updated_at:
              snapshot.updated_at
          }
        end

        def decimal(value)
          return nil if value.blank?

          BigDecimal(
            value.to_s
          ).to_f
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
