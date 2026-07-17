# frozen_string_literal: true

require "bigdecimal"

module ActorLabels
  class HeavyRuleSet
    SOURCE =
      "actor_labels_from_behavior_heavy_v1"

    RULE_VERSION =
      "actor_labels_behavior_heavy_v2"

    MINIMUM_TOP_DESTINATION_PERCENT =
      BigDecimal("80")

    HEAVY_VERSION =
      ActorBehaviors::Heavy::
        BuildFromEvidence::
        HEAVY_VERSION

    ANALYSIS_KIND =
      ActorBehaviors::Heavy::
        BuildFromEvidence::
        ANALYSIS_KIND

    LABEL =
      "exchange_infrastructure_candidate"

    REQUIRED_SIGNALS = %w[
      collection_consolidation_observed
      recurrent_sweep_to_active_wallet
      broad_batch_distribution
      exchange_infrastructure_candidate
      exchange_identity_verified
    ].freeze

    REQUIRED_SCORES = %w[
      deposit_collection_score
      sweep_relation_score
      downstream_distribution_score
      exchange_infrastructure_score
      classification_confidence
    ].freeze

    def self.call(snapshot:)
      new(
        snapshot:
          snapshot
      ).call
    end

    def initialize(snapshot:)
      @snapshot =
        snapshot
    end

    def call
      eligibility =
        eligibility_result

      return eligibility unless
        eligibility[:eligible]

      {
        eligible: true,
        reason: nil,
        source: SOURCE,
        rule_version: RULE_VERSION,
        heavy_version: HEAVY_VERSION,
        labels: labels,
        evidence: compact_evidence
      }
    end

    private

    attr_reader :snapshot

    def eligibility_result
      return ineligible(
        :snapshot_missing
      ) if snapshot.nil?

      unless snapshot.analysis_kind.to_s ==
             ANALYSIS_KIND
        return ineligible(
          :analysis_kind_mismatch
        )
      end

      unless snapshot.status.to_s ==
             "certified"
        return ineligible(
          :heavy_behavior_not_certified
        )
      end

      unless snapshot.heavy_version.to_s ==
             HEAVY_VERSION
        return ineligible(
          :heavy_version_mismatch
        )
      end

      if snapshot.cluster_id.blank?
        return ineligible(
          :source_cluster_id_missing
        )
      end

      if snapshot.downstream_cluster_id.blank?
        return ineligible(
          :downstream_cluster_id_missing
        )
      end

      if snapshot.actor_profile_id.blank?
        return ineligible(
          :actor_profile_id_missing
        )
      end

      unless required_signals_present?
        return ineligible(
          :required_signals_missing
        )
      end

      unless required_scores_present?
        return ineligible(
          :required_scores_missing
        )
      end

      {
        eligible: true,
        reason: nil,
        source: SOURCE,
        rule_version: RULE_VERSION,
        heavy_version: HEAVY_VERSION
      }
    end

    def labels
      return [] unless
        signal?(
          "exchange_infrastructure_candidate"
        )

      return [] unless
        hard_sweep_concentration_gate?

      [
        {
          label: LABEL,

          confidence:
            score(
              "classification_confidence"
            ),

          source:
            SOURCE,

          rule_version:
            RULE_VERSION,

          reason:
            "certified_collection_sweep_" \
            "batch_distribution_chain"
        }
      ]
    end

    def required_signals_present?
      REQUIRED_SIGNALS.all? do |name|
        signals.key?(name)
      end
    end

    def required_scores_present?
      REQUIRED_SCORES.all? do |name|
        scores.key?(name)
      end
    end

    def signal?(name)
      signals[name] == true
    end

    def hard_sweep_concentration_gate?
      value =
        snapshot_evidence.dig(
          "sweep",
          "top_destination_share_percent"
        )

      return false if value.blank?

      BigDecimal(
        value.to_s
      ) >=
        MINIMUM_TOP_DESTINATION_PERCENT
    rescue ArgumentError
      false
    end

    def score(name)
      scores[name]
        .to_i
        .clamp(
          0,
          100
        )
    end

    def signals
      @signals ||=
        snapshot
          .signals
          .to_h
          .stringify_keys
    end

    def scores
      @scores ||=
        snapshot
          .scores
          .to_h
          .stringify_keys
    end

    def snapshot_evidence
      @snapshot_evidence ||=
        snapshot
          .evidence
          .to_h
          .stringify_keys
    end

    def compact_evidence
      {
        actor_behavior_heavy_snapshot_id:
          snapshot.id,

        source_cluster_id:
          snapshot.cluster_id,

        downstream_cluster_id:
          snapshot.downstream_cluster_id,

        actor_profile_id:
          snapshot.actor_profile_id,

        analysis_kind:
          snapshot.analysis_kind,

        heavy_version:
          snapshot.heavy_version,

        heavy_status:
          snapshot.status,

        window_from_height:
          snapshot.window_from_height,

        window_to_height:
          snapshot.window_to_height,

        evidence_fingerprint:
          snapshot.evidence_fingerprint,

        computed_at:
          snapshot.computed_at,

        signals:
          signals,

        scores:
          scores,

        reasons:
          snapshot_evidence.dig(
            "score_evidence",
            "reasons"
          ),

        provenance:
          snapshot_evidence[
            "provenance"
          ]
      }
    end

    def ineligible(reason)
      {
        eligible: false,
        reason: reason,
        source: SOURCE,
        rule_version: RULE_VERSION,
        heavy_version: HEAVY_VERSION,
        labels: [],
        evidence: {}
      }
    end
  end
end
