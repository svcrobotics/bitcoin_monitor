# frozen_string_literal: true

require "bigdecimal"
require "json"

module ActorBehaviors
  class StrictBuildFromProfile
    BEHAVIOR_VERSION = "strict_v2"
    CURRENT_PROFILE_VERSION =
      ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION
    ADVISORY_LOCK_NAMESPACE = 42_021

    # Valeurs reprises des seuils whale audités au moment
    # de l'extraction shadow. La frontière reste à sens unique.
    WHALE_MIN_SCORE = 85

    WHALE_MIN_BALANCE_BTC =
      BigDecimal("1000")

    WHALE_CANDIDATE_MIN_SCORE =
      65

    WHALE_CANDIDATE_MIN_BALANCE_BTC =
      BigDecimal("100")

    MAX_EXCHANGE_SCORE_FOR_WHALE =
      49

    MAX_SERVICE_SCORE_FOR_WHALE =
      49

    EXCHANGE_ADDRESS_THRESHOLDS = [
      [50_000, 100],
      [10_000, 90],
      [1_000, 70],
      [100, 40],
      [10, 15]
    ].freeze

    EXCHANGE_TX_THRESHOLDS = [
      [500_000, 100],
      [100_000, 90],
      [10_000, 70],
      [1_000, 45],
      [100, 20]
    ].freeze

    SERVICE_ADDRESS_THRESHOLDS = [
      [10_000, 85],
      [1_000, 70],
      [100, 45],
      [10, 20]
    ].freeze

    SERVICE_TX_THRESHOLDS = [
      [100_000, 85],
      [10_000, 70],
      [1_000, 45],
      [100, 20]
    ].freeze

    EXCHANGE_LIKE_MIN_SCORE = 70
    SERVICE_LIKE_MIN_SCORE = 70
    ETF_CANDIDATE_MIN_SCORE = 55

    def self.call(actor_profile: nil, actor_profile_id: nil)
      new(
        actor_profile: actor_profile,
        actor_profile_id: actor_profile_id
      ).call
    end

    def initialize(actor_profile: nil, actor_profile_id: nil)
      @actor_profile = actor_profile
      @actor_profile_id =
        actor_profile_id || actor_profile&.id
    end

    def call
      profile =
        load_profile

      unless profile
        return deferred_result(
          reason: :actor_profile_missing
        )
      end

      reason =
        deferred_reason(profile)

      if reason
        return deferred_result(
          reason: reason,
          profile: profile
        )
      end

      fingerprint =
        ActorBehaviors::ProfileFingerprint.call(
          profile
        )

      payload =
        build_behavior_payload(
          profile,
          fingerprint
        )

      transaction_result = nil

      ActorBehaviorSnapshot.transaction do
        unless acquire_cluster_build_lock(profile.cluster_id)
          transaction_result =
            deferred_result(
              reason: :cluster_behavior_locked,
              profile: profile
            )

          next
        end

        current_profile =
          ActorProfile
            .includes(:cluster)
            .find_by(id: profile.id)

        unless current_profile
          transaction_result =
            deferred_result(
              reason: :actor_profile_missing
            )

          next
        end

        current_reason =
          deferred_reason(current_profile)

        if current_reason
          transaction_result =
            deferred_result(
              reason: current_reason,
              profile: current_profile
            )

          next
        end

        current_fingerprint =
          ActorBehaviors::ProfileFingerprint.call(
            current_profile
          )

        if current_fingerprint != fingerprint
          transaction_result =
            deferred_result(
              reason: :source_changed_during_build,
              profile: current_profile
            )

          next
        end

        snapshot =
          ActorBehaviorSnapshot
            .lock
            .find_or_initialize_by(
              cluster_id: profile.cluster_id
            )

        created =
          snapshot.new_record?

        if !created && snapshot_current?(snapshot, payload)
          transaction_result =
            certified_result(
              snapshot: snapshot,
              fingerprint: fingerprint,
              created: false,
              updated: false,
              unchanged: true
            )

          next
        end

        snapshot.assign_attributes(payload)
        snapshot.save!

        transaction_result =
          certified_result(
            snapshot: snapshot,
            fingerprint: fingerprint,
            created: created,
            updated: !created,
            unchanged: false
          )
      end

      transaction_result
    rescue StandardError => error
      {
        ok: false,
        status: "failed",
        snapshot: existing_snapshot,
        reason: :calculation_failed,
        error_class: error.class.name,
        error_message: error.message,
        created: false,
        updated: false,
        unchanged: false,
        source_profile_fingerprint: nil
      }
    end

    private

    attr_reader :actor_profile, :actor_profile_id

    def load_profile
      profile =
        actor_profile ||
        ActorProfile
          .includes(:cluster)
          .find_by(id: actor_profile_id)

      return nil unless profile

      profile.association(:cluster).load_target unless profile.cluster

      profile
    end

    def acquire_cluster_build_lock(cluster_id)
      value =
        ActiveRecord::Base
          .connection
          .select_value(
            "SELECT pg_try_advisory_xact_lock(" \
            "#{ADVISORY_LOCK_NAMESPACE}, " \
            "#{cluster_id.to_i})"
          )

      value == true || value.to_s == "t"
    end

    def deferred_reason(profile)
      return :cluster_missing unless profile.cluster
      return :profile_dirty if profile.dirty?
      return :profile_height_missing if profile.last_computed_height.blank?

      unless profile_version(profile) == CURRENT_PROFILE_VERSION
        return :profile_version_mismatch
      end

      if profile.cluster_composition_version.blank?
        return :profile_composition_version_missing
      end

      if profile.cluster_composition_version.to_i !=
         profile.cluster.composition_version.to_i
        return :cluster_composition_mismatch
      end

      certified =
        ActorProfiles::CertifiedScope
          .call
          .where(id: profile.id)
          .exists?

      return :profile_not_certified unless certified

      nil
    end

    def build_behavior_payload(profile, fingerprint)
      behavior =
        compute_behavior(profile)

      {
        actor_profile_id: profile.id,
        profile_version: profile_version(profile),
        profile_height: profile.last_computed_height,
        cluster_composition_version:
          profile.cluster_composition_version,
        profile_fingerprint: fingerprint,
        behavior_version: BEHAVIOR_VERSION,
        status: "certified",
        signals: behavior.fetch(:signals),
        scores: behavior.fetch(:scores),
        evidence: behavior.fetch(:evidence),
        computed_at: Time.current
      }
    end

    def compute_behavior(profile)
      facts =
        facts_for(profile)

      scores =
        scores_for(facts)

      signals =
        signals_for(
          facts: facts,
          scores: scores
        )

      {
        signals: signals,
        scores: scores,
        evidence:
          evidence_for(
            facts: facts,
            scores: scores,
            signals: signals
          )
      }
    end

    def facts_for(profile)
      traits =
        profile.traits.to_h

      {
        cluster_id: profile.cluster_id.to_i,
        address_count: traits["address_count"].to_i,

        balance_btc:
          decimal_value(profile.balance_btc),

        total_received_btc:
          decimal_value(profile.total_received_btc),

        total_sent_btc:
          decimal_value(profile.total_sent_btc),

        net_btc:
          decimal_value(profile.net_btc),

        tx_count: profile.tx_count.to_i,
        inflow_count: profile.inflow_count.to_i,
        outflow_count: profile.outflow_count.to_i,

        profile_height:
          profile.last_computed_height.to_i,

        cluster_composition_version:
          profile.cluster_composition_version.to_i,

        profile_version:
          profile_version(profile)
      }
    end

    def scores_for(facts)
      balance =
        facts.fetch(:balance_btc).abs

      whale_score =
        if balance >= 10_000
          100
        elsif balance >= 1_000
          85
        elsif balance >= 100
          65
        elsif balance >= 10
          35
        else
          5
        end

      exchange_score = [
        score_by_threshold(
          facts.fetch(:address_count),
          EXCHANGE_ADDRESS_THRESHOLDS
        ),
        score_by_threshold(
          facts.fetch(:tx_count),
          EXCHANGE_TX_THRESHOLDS
        )
      ].max

      service_score = [
        score_by_threshold(
          facts.fetch(:address_count),
          SERVICE_ADDRESS_THRESHOLDS
        ),
        score_by_threshold(
          facts.fetch(:tx_count),
          SERVICE_TX_THRESHOLDS
        )
      ].max

      etf_score =
        etf_score_for(facts)

      {
        whale_score: whale_score,
        exchange_score: exchange_score,
        service_score: service_score,
        etf_score: etf_score
      }
    end

    def signals_for(facts:, scores:)
      balance =
        facts.fetch(:balance_btc).abs

      {
        holder_size: holder_size(balance),
        large_holder: balance >= 1_000,
        very_large_holder: balance >= 10_000,
        whale_like_candidate_inputs:
          whale_like_candidate_inputs?(
            facts: facts,
            scores: scores
          ),
        whale_candidate_inputs:
          whale_candidate_inputs?(
            facts: facts,
            scores: scores
          ),

        exchange_like_candidate_inputs:
          scores.fetch(:exchange_score).to_i >=
            EXCHANGE_LIKE_MIN_SCORE,

        service_like_candidate_inputs:
          scores.fetch(:service_score).to_i >=
            SERVICE_LIKE_MIN_SCORE,

        etf_candidate_inputs:
          scores.fetch(:etf_score).to_i >=
            ETF_CANDIDATE_MIN_SCORE,

        # La définition Retail n’est pas encore certifiée.
        retail_like_candidate_inputs:
          false
      }
    end

    def evidence_for(facts:, scores:, signals:)
      {
        facts: {
          cluster_id: facts.fetch(:cluster_id),
          address_count: facts.fetch(:address_count),
          balance_btc:
            facts.fetch(:balance_btc).to_s("F"),

          total_received_btc:
            facts.fetch(:total_received_btc).to_s("F"),

          total_sent_btc:
            facts.fetch(:total_sent_btc).to_s("F"),

          net_btc:
            facts.fetch(:net_btc).to_s("F"),

          tx_count:
            facts.fetch(:tx_count),

          inflow_count:
            facts.fetch(:inflow_count),

          outflow_count:
            facts.fetch(:outflow_count),

          profile_height:
            facts.fetch(:profile_height),
          cluster_composition_version:
            facts.fetch(:cluster_composition_version),
          profile_version: facts.fetch(:profile_version)
        },
        thresholds: {
          whale_score: {
            very_large_balance_btc: "10000",
            large_balance_btc: "1000",
            candidate_balance_btc: "100",
            small_balance_btc: "10"
          },
          exchange_score: {
            address_count:
              EXCHANGE_ADDRESS_THRESHOLDS,
            tx_count:
              EXCHANGE_TX_THRESHOLDS
          },
          service_score: {
            address_count:
              SERVICE_ADDRESS_THRESHOLDS,
            tx_count:
              SERVICE_TX_THRESHOLDS
          },
          whale_label_inputs: {
            whale_min_score:
              WHALE_MIN_SCORE,
            whale_min_balance_btc:
              WHALE_MIN_BALANCE_BTC.to_s("F"),
            whale_candidate_min_score:
              WHALE_CANDIDATE_MIN_SCORE,
            whale_candidate_min_balance_btc:
              WHALE_CANDIDATE_MIN_BALANCE_BTC.to_s("F"),
            max_exchange_score:
              MAX_EXCHANGE_SCORE_FOR_WHALE,
            max_service_score:
              MAX_SERVICE_SCORE_FOR_WHALE
          },

          actor_label_inputs: {
            exchange_like_min_score:
              EXCHANGE_LIKE_MIN_SCORE,

            service_like_min_score:
              SERVICE_LIKE_MIN_SCORE,

            etf_candidate_min_score:
              ETF_CANDIDATE_MIN_SCORE,

            retail_like_enabled:
              false
          }
        },
        scores: scores,
        signals: signals,
        behavior_version: BEHAVIOR_VERSION,
        reasons: reasons_for(signals)
      }
    end

    def reasons_for(signals)
      reasons = []

      reasons << "balance_maps_to_holder_size"

      if signals.fetch(:whale_like_candidate_inputs)
        reasons << "whale_like_inputs_satisfied"
      elsif signals.fetch(:whale_candidate_inputs)
        reasons << "whale_candidate_inputs_satisfied"
      else
        reasons << "whale_inputs_not_satisfied"
      end

      if signals.fetch(:exchange_like_candidate_inputs)
        reasons << "exchange_like_inputs_satisfied"
      end

      if signals.fetch(:service_like_candidate_inputs)
        reasons << "service_like_inputs_satisfied"
      end

      if signals.fetch(:etf_candidate_inputs)
        reasons << "etf_candidate_inputs_satisfied"
      end

      reasons << "retail_rule_not_defined"

      reasons
    end

    def whale_like_candidate_inputs?(facts:, scores:)
      scores.fetch(:whale_score).to_i >= WHALE_MIN_SCORE &&
        facts.fetch(:balance_btc).abs >= WHALE_MIN_BALANCE_BTC &&
        scores.fetch(:exchange_score).to_i <=
          MAX_EXCHANGE_SCORE_FOR_WHALE &&
        scores.fetch(:service_score).to_i <=
          MAX_SERVICE_SCORE_FOR_WHALE
    end

    def whale_candidate_inputs?(facts:, scores:)
      scores.fetch(:whale_score).to_i >=
        WHALE_CANDIDATE_MIN_SCORE &&
        facts.fetch(:balance_btc).abs >=
          WHALE_CANDIDATE_MIN_BALANCE_BTC &&
        scores.fetch(:exchange_score).to_i <=
          MAX_EXCHANGE_SCORE_FOR_WHALE &&
        scores.fetch(:service_score).to_i <=
          MAX_SERVICE_SCORE_FOR_WHALE
    end

    def etf_score_for(facts)
      balance =
        facts.fetch(:balance_btc).abs

      received =
        facts.fetch(:total_received_btc).abs

      sent =
        facts.fetch(:total_sent_btc).abs

      tx_count =
        facts.fetch(:tx_count).to_i

      inflow_count =
        facts.fetch(:inflow_count).to_i

      outflow_count =
        facts.fetch(:outflow_count).to_i

      return 0 if balance < 50_000
      return 0 if tx_count < 10
      return 0 if tx_count > 2_000
      return 0 if received <= sent
      return 0 if outflow_count > inflow_count

      sent_ratio =
        sent.positive? ? sent / received : BigDecimal("0")

      balance_ratio =
        received.positive? ? balance / received : BigDecimal("0")

      score = 0
      score += 30 if balance >= 50_000
      score += 20 if balance >= 100_000
      score += 20 if balance_ratio >= BigDecimal("0.5")
      score += 15 if sent_ratio <= BigDecimal("0.6")
      score += 15 if outflow_count <= inflow_count

      [score, 100].min
    end

    def decimal_value(value)
      return BigDecimal("0") if value.nil?

      BigDecimal(value.to_s)
    end

    def holder_size(balance)
      if balance >= 10_000
        "very_large"
      elsif balance >= 1_000
        "large"
      elsif balance >= 100
        "candidate"
      elsif balance >= 10
        "small"
      else
        "regular"
      end
    end

    def score_by_threshold(value, thresholds)
      numeric =
        BigDecimal(value.to_s)

      thresholds.each do |threshold, score|
        return score if numeric >=
                        BigDecimal(threshold.to_s)
      end

      0
    end

    def profile_version(profile)
      profile.traits.to_h["profile_version"].to_s
    end

    def snapshot_current?(snapshot, payload)
      snapshot.actor_profile_id == payload.fetch(:actor_profile_id) &&
        snapshot.profile_version == payload.fetch(:profile_version) &&
        snapshot.profile_height == payload.fetch(:profile_height) &&
        snapshot.cluster_composition_version ==
          payload.fetch(:cluster_composition_version) &&
        snapshot.profile_fingerprint ==
          payload.fetch(:profile_fingerprint) &&
        snapshot.behavior_version ==
          payload.fetch(:behavior_version) &&
        snapshot.status == payload.fetch(:status) &&
        snapshot.signals.to_h == canonical_json(payload.fetch(:signals)) &&
        snapshot.scores.to_h == canonical_json(payload.fetch(:scores)) &&
        snapshot.evidence.to_h == canonical_json(payload.fetch(:evidence))
    end

    def canonical_json(value)
      JSON.parse(
        JSON.generate(value)
      )
    end

    def certified_result(
      snapshot:,
      fingerprint:,
      created:,
      updated:,
      unchanged:
    )
      {
        ok: true,
        status: "certified",
        snapshot: snapshot,
        reason: nil,
        created: created,
        updated: updated,
        unchanged: unchanged,
        source_profile_fingerprint: fingerprint
      }
    end

    def deferred_result(reason:, profile: nil)
      {
        ok: true,
        status: "deferred",
        snapshot:
          profile ? existing_snapshot(profile) : nil,
        reason: reason,
        created: false,
        updated: false,
        unchanged: false,
        source_profile_fingerprint:
          profile ? ActorBehaviors::ProfileFingerprint.call(profile) : nil
      }
    end

    def existing_snapshot(profile = nil)
      cluster_id =
        profile&.cluster_id ||
        actor_profile&.cluster_id ||
        ActorProfile
          .where(id: actor_profile_id)
          .pick(:cluster_id)

      return nil unless cluster_id

      ActorBehaviorSnapshot.find_by(
        cluster_id: cluster_id
      )
    end
  end
end
