# frozen_string_literal: true

module ActorLabels
  class StrictRuleSet
    SOURCE =
      "actor_labels_from_behavior_strict_v2"

    RULE_VERSION =
      "actor_labels_behavior_strict_v2_1"

    BEHAVIOR_VERSION =
      ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION

    REQUIRED_SIGNALS = %w[
      whale_like_candidate_inputs
      whale_candidate_inputs
      exchange_like_candidate_inputs
      service_like_candidate_inputs
      etf_candidate_inputs
      retail_like_candidate_inputs
    ].freeze

    def self.call(snapshot:)
      new(snapshot: snapshot).call
    end

    def initialize(snapshot:)
      @snapshot = snapshot
    end

    def call
      eligibility =
        eligibility_result

      return eligibility unless eligibility[:eligible]

      {
        eligible: true,
        reason: nil,
        source: SOURCE,
        rule_version: RULE_VERSION,
        behavior_version: BEHAVIOR_VERSION,
        labels: labels,
        evidence: evidence
      }
    end

    private

    attr_reader :snapshot

    def eligibility_result
      return ineligible(:snapshot_missing) if snapshot.nil?

      unless snapshot.status.to_s == "certified"
        return ineligible(:behavior_not_certified)
      end

      unless snapshot.behavior_version.to_s ==
             BEHAVIOR_VERSION
        return ineligible(:behavior_version_mismatch)
      end

      return ineligible(:cluster_id_missing) if snapshot.cluster_id.blank?

      if snapshot.actor_profile_id.blank?
        return ineligible(:actor_profile_id_missing)
      end

      unless required_signals_present?
        return ineligible(:required_signals_missing)
      end

      {
        eligible: true,
        reason: nil,
        source: SOURCE,
        rule_version: RULE_VERSION,
        behavior_version: BEHAVIOR_VERSION
      }
    end

    def required_signals_present?
      REQUIRED_SIGNALS.all? do |name|
        signals.key?(name)
      end
    end

    def labels
      result = []

      if signal?("whale_like_candidate_inputs")
        result << build_label(
          name: "whale_like",
          confidence: score("whale_score"),
          reason: "certified_behavior_whale_like_inputs"
        )
      elsif signal?("whale_candidate_inputs")
        result << build_label(
          name: "whale_candidate",
          confidence: score("whale_score"),
          reason: "certified_behavior_whale_candidate_inputs"
        )
      end

      if signal?("exchange_like_candidate_inputs")
        result << build_label(
          name: "exchange_like",
          confidence: score("exchange_score"),
          reason: "certified_behavior_exchange_like_inputs"
        )
      end

      if signal?("service_like_candidate_inputs")
        result << build_label(
          name: "service_like",
          confidence: score("service_score"),
          reason: "certified_behavior_service_like_inputs"
        )
      end

      if signal?("etf_candidate_inputs")
        result << build_label(
          name: "etf_candidate",
          confidence: score("etf_score"),
          reason: "certified_behavior_etf_candidate_inputs"
        )
      end

      # etf_like exige une identité vérifiée.
      # retail_like reste désactivé tant que sa règle n’est pas certifiée.
      result
    end

    def signal?(name)
      signals[name] == true
    end

    def score(name)
      scores[name].to_i.clamp(0, 100)
    end

    def build_label(name:, confidence:, reason:)
      {
        label: name,
        confidence: confidence,
        source: SOURCE,
        rule_version: RULE_VERSION,
        reason: reason
      }
    end

    def signals
      @signals ||= snapshot.signals.to_h
    end

    def scores
      @scores ||= snapshot.scores.to_h
    end

    def evidence
      {
        actor_behavior_snapshot_id:
          snapshot.id,

        cluster_id:
          snapshot.cluster_id,

        actor_profile_id:
          snapshot.actor_profile_id,

        profile_version:
          snapshot.profile_version,

        profile_height:
          snapshot.profile_height,

        cluster_composition_version:
          snapshot.cluster_composition_version,

        profile_fingerprint:
          snapshot.profile_fingerprint,

        behavior_version:
          snapshot.behavior_version,

        behavior_status:
          snapshot.status,

        behavior_computed_at:
          snapshot.computed_at,

        signals:
          signals,

        scores:
          scores,

        behavior_evidence:
          snapshot.evidence.to_h
      }
    end

    def ineligible(reason)
      {
        eligible: false,
        reason: reason,
        source: SOURCE,
        rule_version: RULE_VERSION,
        behavior_version: BEHAVIOR_VERSION,
        labels: [],
        evidence: {}
      }
    end
  end
end
