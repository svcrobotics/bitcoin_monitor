# frozen_string_literal: true

require "bigdecimal"

module ActorLabels
  class BehavioralExtensionRuleSet
    SOURCE = "actor_labels_from_behavioral_extension_v1"
    RULE_VERSION = "actor_labels_behavioral_extension_v1_1"
    BEHAVIOR_VERSION = "strict_v2"

    RETENTION_LABEL = "high_retention_behavior"
    SPEND_THROUGH_LABEL = "high_spend_through_behavior"

    RETENTION_RATIO_THRESHOLD = BigDecimal("0.80")
    RETENTION_MIN_RECEIVED_TRANSACTIONS = 20
    SPEND_THROUGH_RATIO_THRESHOLD = BigDecimal("0.95")
    SPEND_THROUGH_MIN_SPENDING_TRANSACTIONS = 20

    REQUIRED_FACTS = %w[
      balance_btc
      total_received_btc
      total_sent_btc
      inflow_count
      outflow_count
    ].freeze

    def self.call(snapshot:, scope_verified: false)
      new(snapshot: snapshot, scope_verified: scope_verified).call
    end

    def initialize(snapshot:, scope_verified: false)
      @snapshot = snapshot
      @scope_verified = scope_verified == true
    end

    def call
      eligibility = eligibility_result
      return ineligible(eligibility[:reason]) unless eligibility[:eligible]

      facts = financial_facts
      retention_ratio = facts.fetch("balance_btc") / facts.fetch("total_received_btc")
      spend_through_ratio = facts.fetch("total_sent_btc") / facts.fetch("total_received_btc")

      labels = []
      if retention_ratio >= RETENTION_RATIO_THRESHOLD &&
         facts.fetch("inflow_count") >= RETENTION_MIN_RECEIVED_TRANSACTIONS
        labels << build_label(
          name: RETENTION_LABEL,
          confidence: confidence_for(retention_ratio, RETENTION_RATIO_THRESHOLD),
          reason: "certified_high_retention_ratio"
        )
      end

      if spend_through_ratio >= SPEND_THROUGH_RATIO_THRESHOLD &&
         facts.fetch("outflow_count") >= SPEND_THROUGH_MIN_SPENDING_TRANSACTIONS
        labels << build_label(
          name: SPEND_THROUGH_LABEL,
          confidence: confidence_for(spend_through_ratio, SPEND_THROUGH_RATIO_THRESHOLD),
          reason: "certified_high_spend_through_ratio"
        )
      end

      {
        eligible: true,
        reason: nil,
        source: SOURCE,
        rule_version: RULE_VERSION,
        behavior_version: BEHAVIOR_VERSION,
        labels: labels,
        evidence: evidence(
          facts: facts,
          retention_ratio: retention_ratio,
          spend_through_ratio: spend_through_ratio
        )
      }
    end

    private

    attr_reader :snapshot, :scope_verified

    def eligibility_result
      return { eligible: false, reason: :snapshot_missing } unless snapshot
      return { eligible: false, reason: :behavior_version_mismatch } unless snapshot.behavior_version.to_s == BEHAVIOR_VERSION
      return { eligible: false, reason: :behavior_not_certified } unless snapshot.status.to_s == "certified"
      return { eligible: false, reason: :certification_scope_mismatch } unless snapshot.certification_scope.to_s == "strict"
      return { eligible: false, reason: :fingerprint_missing } if snapshot.source_hash.blank? || snapshot.profile_fingerprint.blank?
      return { eligible: false, reason: :fingerprint_mismatch } unless snapshot.source_hash.to_s == snapshot.profile_fingerprint.to_s
      return { eligible: false, reason: :certified_scope_mismatch } unless scope_verified || current_certified_snapshot?

      facts = financial_facts
      return { eligible: false, reason: :required_facts_missing } unless facts
      return { eligible: false, reason: :total_received_not_positive } unless facts.fetch("total_received_btc").positive?
      return { eligible: false, reason: :negative_financial_fact } if facts.values_at("balance_btc", "total_sent_btc").any?(&:negative?)
      return { eligible: false, reason: :accounting_identity_mismatch } unless facts.fetch("total_received_btc") == facts.fetch("balance_btc") + facts.fetch("total_sent_btc")
      return { eligible: false, reason: :negative_activity_count } if facts.values_at("inflow_count", "outflow_count").any?(&:negative?)

      { eligible: true, reason: nil }
    rescue ArgumentError, KeyError
      { eligible: false, reason: :invalid_certified_facts }
    end

    def current_certified_snapshot?
      ActorBehaviors::CertifiedScope.call.where(id: snapshot.id).exists?
    rescue StandardError
      false
    end

    def financial_facts
      @financial_facts ||= begin
        raw = snapshot.evidence.to_h.fetch("facts")
        return nil unless REQUIRED_FACTS.all? { |key| raw.key?(key) && !raw[key].nil? }

        {
          "balance_btc" => BigDecimal(raw.fetch("balance_btc").to_s),
          "total_received_btc" => BigDecimal(raw.fetch("total_received_btc").to_s),
          "total_sent_btc" => BigDecimal(raw.fetch("total_sent_btc").to_s),
          "inflow_count" => Integer(raw.fetch("inflow_count")),
          "outflow_count" => Integer(raw.fetch("outflow_count"))
        }
      end
    end

    def confidence_for(ratio, threshold)
      ((ratio * 100).round).clamp(threshold * 100, 100).to_i
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

    def evidence(facts:, retention_ratio:, spend_through_ratio:)
      {
        actor_behavior_snapshot_id: snapshot.id,
        actor_profile_id: snapshot.actor_profile_id,
        cluster_id: snapshot.cluster_id,
        behavior_version: snapshot.behavior_version,
        behavior_status: snapshot.status,
        certification_scope: snapshot.certification_scope,
        profile_version: snapshot.profile_version,
        profile_height: snapshot.profile_height,
        cluster_composition_version: snapshot.cluster_composition_version,
        profile_fingerprint: snapshot.profile_fingerprint,
        source_hash: snapshot.source_hash,
        computed_at: snapshot.computed_at,
        facts: facts,
        ratios: {
          retention_ratio: retention_ratio.to_s("F"),
          spend_through_ratio: spend_through_ratio.to_s("F")
        },
        thresholds: {
          retention_ratio: RETENTION_RATIO_THRESHOLD.to_s("F"),
          retention_min_received_transactions: RETENTION_MIN_RECEIVED_TRANSACTIONS,
          spend_through_ratio: SPEND_THROUGH_RATIO_THRESHOLD.to_s("F"),
          spend_through_min_spending_transactions: SPEND_THROUGH_MIN_SPENDING_TRANSACTIONS
        }
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
