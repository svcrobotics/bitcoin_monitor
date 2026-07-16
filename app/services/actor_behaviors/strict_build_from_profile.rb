# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "json"

module ActorBehaviors
  class StrictBuildFromProfile
    BEHAVIOR_VERSION = "strict_v2"
    ADVISORY_LOCK_NAMESPACE = 42_021
    EXCHANGE_ADDRESS_THRESHOLDS = [[50_000, 100], [10_000, 90], [1_000, 70],
      [100, 40], [10, 15]].freeze
    EXCHANGE_TX_THRESHOLDS = [[500_000, 100], [100_000, 90], [10_000, 70],
      [1_000, 45], [100, 20]].freeze
    SERVICE_ADDRESS_THRESHOLDS = [[10_000, 85], [1_000, 70], [100, 45],
      [10, 20]].freeze
    SERVICE_TX_THRESHOLDS = [[100_000, 85], [10_000, 70], [1_000, 45],
      [100, 20]].freeze

    def self.call(cluster_id:, cluster_composition_version:, profile_version:,
      source_height:, source_hash:)
      new(cluster_id:, cluster_composition_version:, profile_version:,
        source_height:, source_hash:).call
    end

    def initialize(cluster_id:, cluster_composition_version:, profile_version:,
      source_height:, source_hash:)
      @cluster_id = positive_integer(cluster_id, :cluster_id)
      @composition_version = positive_integer(
        cluster_composition_version, :cluster_composition_version
      )
      @profile_version = profile_version.to_s
      @source_height = nonnegative_integer(source_height, :source_height)
      @source_hash = source_hash.to_s
      raise ArgumentError, "profile_version must be present" if @profile_version.empty?
      raise ArgumentError, "source_hash must be present" if @source_hash.empty?
    end

    def call
      ActiveRecord::Base.transaction(requires_new: true) do
        acquire_build_lock
        profile = ActorProfile.lock.find_by(cluster_id: @cluster_id)
        return refused("certified_profile_missing") unless profile

        version_result = validate_requested_version(profile)
        return version_result if version_result

        snapshot = ActorBehaviorSnapshot.lock.find_or_initialize_by(cluster_id: @cluster_id)
        if current?(snapshot, profile)
          handoff = ActorLabels::HandoffRegistration.call(snapshot: snapshot)
          return already_current(snapshot).merge(actor_label_handoff_id: handoff[:handoff_id])
        end

        payload = build_payload(profile)
        snapshot.assign_attributes(payload)
        persist_snapshot!(snapshot)
        handoff = ActorLabels::HandoffRegistration.call(snapshot: snapshot)

        result("built", snapshot).merge(actor_label_handoff_id: handoff[:handoff_id])
      end
    end

    private

    def validate_requested_version(profile)
      current_composition = profile.cluster_composition_version.to_i
      current_height = profile.last_computed_height.to_i
      current_hash = profile.metadata.to_h["address_spend_projection_hash"].to_s
      current_profile_version = profile.traits.to_h["profile_version"].to_s

      if @composition_version > current_composition || @source_height > current_height
        return refused("future_profile_version")
      end

      if @composition_version < current_composition || @source_height < current_height ||
          @source_hash != current_hash || @profile_version != current_profile_version
        return superseded_or_refused
      end

      return refused("profile_not_strictly_certified") unless
        profile.certification_scope == "strict" && profile.certified_at.present? &&
          !profile.dirty? && profile.metadata.to_h["strict"] == true

      handoff = ActorBehaviorBuildHandoff.exists?(
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        profile_version: @profile_version,
        source_height: @source_height,
        source_hash: @source_hash
      )
      return refused("durable_handoff_missing") unless handoff

      nil
    end

    def superseded_or_refused
      newer = ActorBehaviorBuildHandoff.where(cluster_id: @cluster_id).where(
        "cluster_composition_version > ? OR source_height > ?",
        @composition_version, @source_height
      ).exists?
      newer ? terminal("superseded", "newer_durable_handoff") :
        refused("newer_handoff_missing")
    end

    def current?(snapshot, profile)
      snapshot.persisted? && snapshot.status == "certified" &&
        snapshot.actor_profile_id == profile.id &&
        snapshot.cluster_composition_version.to_i == @composition_version &&
        snapshot.profile_version == @profile_version &&
        snapshot.profile_height.to_i == @source_height &&
        snapshot.source_hash == @source_hash &&
        snapshot.behavior_version == BEHAVIOR_VERSION &&
        snapshot.certification_scope == "strict" && snapshot.certified_at.present?
    end

    def persist_snapshot!(snapshot)
      snapshot.save!
    end

    def already_current(snapshot)
      result("already_current", snapshot)
    end

    def build_payload(profile)
      facts = facts_for(profile)
      scores = scores_for(facts)
      signals = signals_for(facts, scores)
      {
        actor_profile_id: profile.id,
        profile_version: @profile_version,
        profile_height: @source_height,
        cluster_composition_version: @composition_version,
        profile_fingerprint: profile_fingerprint(profile),
        behavior_version: BEHAVIOR_VERSION,
        status: "certified",
        source_hash: @source_hash,
        certification_scope: "strict",
        certified_at: Time.current,
        computed_at: Time.current,
        signals: signals,
        scores: scores,
        evidence: {
          "facts" => facts.transform_values { |value| serialize(value) },
          "ruleset" => BEHAVIOR_VERSION,
          "source_height" => @source_height,
          "source_hash" => @source_hash
        }
      }
    end

    def facts_for(profile)
      {
        "address_count" => profile.traits.to_h["address_count"].to_i,
        "balance_btc" => decimal(profile.balance_btc),
        "total_received_btc" => decimal(profile.total_received_btc),
        "total_sent_btc" => decimal(profile.total_sent_btc),
        "net_btc" => decimal(profile.net_btc),
        "tx_count" => profile.tx_count.to_i,
        "inflow_count" => profile.inflow_count.to_i,
        "outflow_count" => profile.outflow_count.to_i
      }
    end

    def scores_for(facts)
      balance = facts.fetch("balance_btc").abs
      whale = if balance >= 10_000 then 100
        elsif balance >= 1_000 then 85
        elsif balance >= 100 then 65
        elsif balance >= 10 then 35
        else 5 end
      {
        "whale_score" => whale,
        "exchange_score" => [
          score_by_threshold(facts.fetch("address_count"), EXCHANGE_ADDRESS_THRESHOLDS),
          score_by_threshold(facts.fetch("tx_count"), EXCHANGE_TX_THRESHOLDS)
        ].max,
        "service_score" => [
          score_by_threshold(facts.fetch("address_count"), SERVICE_ADDRESS_THRESHOLDS),
          score_by_threshold(facts.fetch("tx_count"), SERVICE_TX_THRESHOLDS)
        ].max,
        "etf_score" => etf_score_for(facts)
      }
    end

    def signals_for(facts, scores)
      balance = facts.fetch("balance_btc").abs
      {
        "holder_size" => holder_size(balance),
        "large_holder" => balance >= 1_000,
        "very_large_holder" => balance >= 10_000,
        "whale_like_candidate_inputs" =>
          scores.fetch("whale_score") >= 85 && balance >= 1_000 &&
            scores.fetch("exchange_score") <= 49 && scores.fetch("service_score") <= 49,
        "whale_candidate_inputs" =>
          scores.fetch("whale_score") >= 65 && balance >= 100 &&
            scores.fetch("exchange_score") <= 49 && scores.fetch("service_score") <= 49,
        "exchange_like_candidate_inputs" => scores.fetch("exchange_score") >= 70,
        "service_like_candidate_inputs" => scores.fetch("service_score") >= 70,
        "etf_candidate_inputs" => scores.fetch("etf_score") >= 55,
        "retail_like_candidate_inputs" => false
      }
    end

    def etf_score_for(facts)
      balance = facts.fetch("balance_btc").abs
      received = facts.fetch("total_received_btc").abs
      sent = facts.fetch("total_sent_btc").abs
      tx_count = facts.fetch("tx_count")
      inflow_count = facts.fetch("inflow_count")
      outflow_count = facts.fetch("outflow_count")
      return 0 if balance < 50_000 || tx_count < 10 || tx_count > 2_000
      return 0 if received <= sent || outflow_count > inflow_count

      sent_ratio = sent.positive? ? sent / received : BigDecimal("0")
      balance_ratio = received.positive? ? balance / received : BigDecimal("0")
      score = 0
      score += 30 if balance >= 50_000
      score += 20 if balance >= 100_000
      score += 20 if balance_ratio >= BigDecimal("0.5")
      score += 15 if sent_ratio <= BigDecimal("0.6")
      score += 15 if outflow_count <= inflow_count
      [score, 100].min
    end

    def holder_size(balance)
      return "very_large" if balance >= 10_000
      return "large" if balance >= 1_000
      return "candidate" if balance >= 100
      return "small" if balance >= 10

      "regular"
    end

    def score_by_threshold(value, thresholds)
      numeric = BigDecimal(value.to_s)
      thresholds.each { |threshold, score| return score if numeric >= threshold }
      0
    end

    def profile_fingerprint(profile)
      Digest::SHA256.hexdigest(JSON.generate({
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        profile_version: @profile_version,
        source_height: @source_height,
        source_hash: @source_hash,
        facts: facts_for(profile).transform_values { |value| serialize(value) }
      }))
    end

    def result(status, snapshot)
      {
        ok: true,
        status: status,
        snapshot_id: snapshot.id,
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        profile_version: @profile_version,
        source_height: @source_height,
        source_hash: @source_hash,
        behavior_version: BEHAVIOR_VERSION
      }
    end

    def refused(reason)
      terminal("refused", reason)
    end

    def terminal(status, reason)
      {
        ok: status != "refused",
        status: status,
        reason: reason,
        cluster_id: @cluster_id,
        cluster_composition_version: @composition_version,
        profile_version: @profile_version,
        source_height: @source_height,
        source_hash: @source_hash
      }
    end

    def acquire_build_lock
      ActiveRecord::Base.connection.select_value(
        "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_NAMESPACE}, #{@cluster_id})"
      )
    end

    def serialize(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value
    end

    def decimal(value)
      BigDecimal(value.to_s.presence || "0")
    end

    def positive_integer(value, name)
      integer = value.is_a?(String) ? Integer(value, 10) : Integer(value)
      raise ArgumentError unless integer.positive?
      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a positive integer"
    end

    def nonnegative_integer(value, name)
      integer = value.is_a?(String) ? Integer(value, 10) : Integer(value)
      raise ArgumentError if integer.negative?
      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a nonnegative integer"
    end
  end
end
