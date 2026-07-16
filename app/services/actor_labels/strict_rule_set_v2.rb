# frozen_string_literal: true

require "bigdecimal"

module ActorLabels
  class StrictRuleSetV2
    SOURCE = "actor_labels_strict_v3_core"
    RULE_VERSION = "actor_labels_strict_v3_core_1"
    ACTIVE_RULES = %w[whale_like whale_candidate].freeze
    DEFERRED_RULES = %w[accumulator_like distributor_like etf_candidate].freeze
    PROFILE_VERSION = "strict_v3_core"
    FRESHNESS_BASIS = "actor_profile_certified_scope_v3_core"

    WHALE_MIN_SCORE = 85
    WHALE_MIN_BALANCE_BTC = BigDecimal("1000")

    WHALE_CANDIDATE_MIN_SCORE = 65
    WHALE_CANDIDATE_MIN_BALANCE_BTC = BigDecimal("100")

    MAX_EXCHANGE_SCORE_FOR_WHALE = 49
    MAX_SERVICE_SCORE_FOR_WHALE = 49

    HIGH_ACTIVITY_MIN_SCORE = 70
    FLOW_BEHAVIOR_MIN_SCORE = 70
    ETF_CANDIDATE_MIN_SCORE = 55

    def self.call(profile:, cluster_tip:)
      new(
        profile: profile,
        cluster_tip: cluster_tip
      ).call
    end

    def initialize(profile:, cluster_tip:)
      @profile = profile
      @cluster_tip = cluster_tip.to_i
    end

    def call
      eligibility = eligibility_result
      return eligibility unless eligibility[:eligible]

      {
        eligible: true,
        reason: nil,
        profile_lag: profile_lag,
        global_tip_lag: global_tip_lag,
        cluster_required_height: cluster_required_height,
        freshness_basis: FRESHNESS_BASIS,
        labels: labels,
        evidence: evidence
      }
    end

    private

    attr_reader :profile, :cluster_tip

    def eligibility_result
      return ineligible(:cluster_tip_missing) if cluster_tip.zero?
      return ineligible(:cluster_missing) unless cluster
      return ineligible(:cluster_without_addresses) unless cluster_has_addresses?
      return ineligible(:profile_dirty) if profile.dirty?
      return ineligible(:profile_height_missing) if profile.last_computed_height.blank?
      return ineligible(:profile_not_strict_v3_core) unless strict_core_profile?

      if profile.cluster_composition_version.blank?
        return ineligible(
          :profile_composition_version_missing
        )
      end

      if profile.cluster_composition_version.to_i !=
         cluster.composition_version.to_i
        return ineligible(
          :cluster_composition_mismatch
        )
      end

      return ineligible(:cluster_height_missing) if cluster_required_height.nil?
      return ineligible(:profile_ahead_of_cluster) if global_tip_lag.negative?
      return ineligible(:profile_too_stale) if profile_lag.positive?

      {
        eligible: true,
        reason: nil,
        profile_lag: profile_lag,
        global_tip_lag: global_tip_lag,
        cluster_required_height: cluster_required_height,
        freshness_basis: FRESHNESS_BASIS
      }
    end

    def labels
      result = []

      if whale_like?
        result << build_label(
          name: "whale_like",
          confidence: profile.whale_score.to_i,
          reason:
            "large_balance_with_low_exchange_and_service_activity"
        )
      elsif whale_candidate?
        result << build_label(
          name: "whale_candidate",
          confidence: profile.whale_score.to_i,
          reason:
            "large_holder_below_strict_whale_threshold"
        )
      end

      result
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

    def whale_like?
      profile.whale_score.to_i >=
        WHALE_MIN_SCORE &&
        profile.balance_btc.to_d.abs >=
          WHALE_MIN_BALANCE_BTC &&
        profile.exchange_score.to_i <=
          MAX_EXCHANGE_SCORE_FOR_WHALE &&
        profile.service_score.to_i <=
          MAX_SERVICE_SCORE_FOR_WHALE
    end

    def whale_candidate?
      profile.whale_score.to_i >=
        WHALE_CANDIDATE_MIN_SCORE &&
        profile.balance_btc.to_d.abs >=
          WHALE_CANDIDATE_MIN_BALANCE_BTC &&
        profile.exchange_score.to_i <=
          MAX_EXCHANGE_SCORE_FOR_WHALE &&
        profile.service_score.to_i <=
          MAX_SERVICE_SCORE_FOR_WHALE
    end

    def strict_core_profile?
      metadata = profile.metadata.to_h
      traits = profile.traits.to_h

      metadata["strict"] == true &&
        traits["profile_version"] ==
          PROFILE_VERSION
    end

    def cluster
      return @cluster if defined?(@cluster)

      @cluster = profile.cluster
    end

    def cluster_has_addresses?
      Address.exists?(
        cluster_id: cluster.id
      )
    end

    def profile_address_count
      profile.traits.to_h["address_count"].to_i
    end

    def cluster_required_height
      height = cluster&.last_seen_height

      height.nil? ? nil : height.to_i
    end

    def profile_lag
      return nil if profile.last_computed_height.blank?
      return nil if cluster_required_height.nil?

      cluster_required_height -
        profile.last_computed_height.to_i
    end

    def global_tip_lag
      return nil if profile.last_computed_height.blank?
      return nil if cluster_tip.zero?

      cluster_tip -
        profile.last_computed_height.to_i
    end

    def evidence
      {
        actor_profile_id:
          profile.id,

        cluster_id:
          profile.cluster_id,

        profile_version:
          PROFILE_VERSION,

        profile_height:
          profile.last_computed_height,

        cluster_required_height:
          cluster_required_height,

        cluster_tip:
          cluster_tip,

        profile_cluster_composition_version:
          profile.cluster_composition_version,

        cluster_composition_version:
          cluster.composition_version,

        profile_lag:
          profile_lag,

        global_tip_lag:
          global_tip_lag,

        freshness_basis:
          FRESHNESS_BASIS,

        scores: {
          whale:
            profile.whale_score.to_i,

          exchange:
            profile.exchange_score.to_i,

          service:
            profile.service_score.to_i,

          etf:
            nil,

          accumulation:
            nil,

          distribution:
            nil
        },

        metrics: {
          address_count:
            profile_address_count,

          balance_btc:
            profile.balance_btc.to_s,

          total_received_btc:
            nil,

          total_sent_btc:
            profile.total_sent_btc.to_s,

          tx_count:
            profile.tx_count.to_i,

          spent_tx_count:
            profile.tx_count.to_i,

          inflow_count:
            nil,

          outflow_count:
            profile.outflow_count.to_i
        },

        profile_updated_at:
          profile.updated_at
      }
    end

    def ineligible(reason)
      {
        eligible: false,
        reason: reason,
        profile_lag: profile_lag,
        global_tip_lag: global_tip_lag,
        cluster_required_height: cluster_required_height,
        freshness_basis: FRESHNESS_BASIS,
        labels: [],
        evidence: {}
      }
    end
  end
end
