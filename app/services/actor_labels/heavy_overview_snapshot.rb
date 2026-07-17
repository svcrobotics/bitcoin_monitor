# frozen_string_literal: true

module ActorLabels
  class HeavyOverviewSnapshot
    LABEL =
      "exchange_infrastructure_candidate"

    SOURCE =
      ActorLabels::HeavyRuleSet::SOURCE

    CURRENT_HEAVY_VERSION =
      ActorBehaviors::Heavy::
        BuildFromEvidence::
        HEAVY_VERSION

    ANALYSIS_KIND =
      ActorBehaviors::Heavy::
        BuildFromEvidence::
        ANALYSIS_KIND

    DISPLAY_LIMIT = 20

    def self.call
      new.call
    end

    def call
      current_scope =
        ActorBehaviorHeavySnapshot
          .where(
            status: "certified",
            analysis_kind:
              ANALYSIS_KIND,
            heavy_version:
              CURRENT_HEAVY_VERSION
          )

      candidates =
        current_scope.where(
          "signals ->> " \
          "'exchange_infrastructure_candidate' = ?",
          "true"
        )

      rejected =
        current_scope.where(
          "COALESCE(" \
          "signals ->> " \
          "'exchange_infrastructure_candidate', " \
          "'false'" \
          ") <> ?",
          "true"
        )

      records =
        candidates
          .order(updated_at: :desc)
          .limit(DISPLAY_LIMIT)
          .to_a +
        rejected
          .order(updated_at: :desc)
          .limit(DISPLAY_LIMIT)
          .to_a

      published_scope =
        ActorLabels::
          CurrentHeavyExchangeLabelScope
          .call

      published_cluster_ids =
        published_scope
          .where(
            cluster_id:
              records.map(&:cluster_id)
          )
          .pluck(:cluster_id)
          .to_set

      {
        status:
          current_scope.exists? ?
            "active" :
            "empty",

        analyzed:
          current_scope.count,

        candidates:
          candidates.count,

        rejected:
          rejected.count,

        labels_published:
          published_scope.count,

        minimum_sweep_share_percent:
          80.0,

        heavy_version:
          CURRENT_HEAVY_VERSION,

        builder_version:
          ActorBehaviors::Heavy::
            Build::VERSION,

        score_version:
          ActorBehaviors::Heavy::
            ExchangeInfrastructureScore::
            VERSION,

        rule_version:
          ActorLabels::HeavyRuleSet::
            RULE_VERSION,

        automatic:
          false,

        scheduler_enabled:
          false,

        identity_verified:
          false,

        cases:
          records.map do |snapshot|
            case_payload(
              snapshot,
              published:
                published_cluster_ids.include?(
                  snapshot.cluster_id
                )
            )
          end,

        generated_at:
          Time.current
      }
    rescue StandardError => error
      {
        status: "unavailable",
        analyzed: 0,
        candidates: 0,
        rejected: 0,
        labels_published: 0,
        cases: [],
        error_class: error.class.name,
        error_message: error.message,
        generated_at: Time.current
      }
    end

    private

    def case_payload(
      snapshot,
      published:
    )
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

      sweep =
        evidence
          .fetch("sweep", {})
          .to_h
          .stringify_keys

      distribution =
        evidence
          .fetch(
            "downstream_distribution",
            {}
          )
          .to_h
          .stringify_keys

      candidate =
        signals[
          "exchange_infrastructure_candidate"
        ] == true

      {
        snapshot_id:
          snapshot.id,

        source_cluster_id:
          snapshot.cluster_id,

        downstream_cluster_id:
          snapshot.downstream_cluster_id,

        candidate:
          candidate,

        label_published:
          published,

        confidence:
          scores[
            "classification_confidence"
          ].to_i,

        infrastructure_score:
          scores[
            "exchange_infrastructure_score"
          ].to_i,

        deposit_score:
          scores[
            "deposit_collection_score"
          ].to_i,

        sweep_score:
          scores[
            "sweep_relation_score"
          ].to_i,

        distribution_score:
          scores[
            "downstream_distribution_score"
          ].to_i,

        sweep_share_percent:
          decimal(
            sweep[
              "top_destination_share_percent"
            ]
          ),

        consolidation_transactions:
          sweep[
            "consolidation_transactions"
          ].to_i,

        consolidation_blocks:
          sweep[
            "consolidation_blocks"
          ].to_i,

        distribution_transactions:
          distribution[
            "spending_transactions"
          ].to_i,

        distribution_blocks:
          distribution[
            "spending_blocks"
          ].to_i,

        batch_percent:
          decimal(
            distribution[
              "batch_transaction_percent"
            ]
          ),

        external_addresses:
          distribution[
            "distinct_external_addresses"
          ].to_i,

        external_clusters:
          distribution[
            "distinct_external_clusters"
          ].to_i,

        identity_verified:
          signals[
            "exchange_identity_verified"
          ] == true,

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
          evidence.dig(
            "score_evidence",
            "version"
          ),

        updated_at:
          snapshot.updated_at
      }
    end

    def decimal(value)
      return nil if value.blank?

      BigDecimal(
        value.to_s
      ).to_f
    rescue ArgumentError
      nil
    end
  end
end
