# frozen_string_literal: true

module ActorLabels
  class StrictEvaluateFromBehavior
    SOURCE = CertifiedRuleSet::SOURCE
    LOCK_NAMESPACE = 42_023

    def self.call(**arguments) = new(**arguments).call

    def initialize(cluster_id:, cluster_composition_version:, profile_version:,
      source_height:, source_hash:, behavior_version:, behavior_snapshot_id:,
      rule_version:)
      @cluster_id = Integer(cluster_id)
      @composition = Integer(cluster_composition_version)
      @profile_version = profile_version.to_s
      @height = Integer(source_height)
      @source_hash = source_hash.to_s
      @behavior_version = behavior_version.to_s
      @snapshot_id = Integer(behavior_snapshot_id)
      @rule_version = rule_version.to_s
      raise ArgumentError unless @cluster_id.positive? && @composition.positive? &&
        @height >= 0 && @snapshot_id.positive?
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid ActorLabel evaluation identity"
    end

    def call
      ActiveRecord::Base.transaction(requires_new: true) do
        lock_cluster
        snapshot = ActorBehaviorSnapshot.lock.find_by(id: @snapshot_id)
        return refused("snapshot_missing") unless exact_snapshot?(snapshot)
        return refused("unknown_rule_version") unless
          @rule_version == CertifiedRuleSet::RULE_VERSION
        return superseded_or_refused unless durable_handoff?

        existing = ActorLabelEvaluation.find_by(identity)
        return result("already_current", existing) if existing

        rules = CertifiedRuleSet.call(snapshot: snapshot)
        persist_labels(snapshot, rules)
        evaluation = ActorLabelEvaluation.create!(identity.merge(
          status: "certified", certification_scope: "strict",
          rule_results: rules[:rule_results], active_rules: rules[:active_rules],
          deferred_rules: rules[:deferred_rules], certified_at: Time.current))
        result("evaluated", evaluation)
      end
    end

    private

    def exact_snapshot?(snapshot)
      snapshot && snapshot.status == "certified" &&
        snapshot.certification_scope == "strict" && snapshot.certified_at.present? &&
        snapshot.cluster_id == @cluster_id &&
        snapshot.cluster_composition_version.to_i == @composition &&
        snapshot.profile_version == @profile_version &&
        snapshot.profile_height.to_i == @height && snapshot.source_hash == @source_hash &&
        snapshot.behavior_version == @behavior_version
    end

    def durable_handoff?
      ActorLabelHandoff.exists?(identity.except(:actor_behavior_snapshot_id).merge(
        actor_behavior_snapshot_id: @snapshot_id))
    end

    def superseded_or_refused
      newer = ActorLabelHandoff.where(cluster_id: @cluster_id).where(
        "source_height > ? OR actor_behavior_snapshot_id > ?", @height, @snapshot_id).exists?
      newer ? terminal("superseded", "newer_durable_handoff") :
        refused("durable_handoff_missing")
    end

    def persist_labels(snapshot, rules)
      expected = rules[:labels].map { |label| label[:label] }
      scope = ActorLabel.where(cluster_id: @cluster_id, source: SOURCE)
      expected.empty? ? scope.delete_all : scope.where.not(label: expected).delete_all
      rules[:labels].each do |data|
        label = scope.find_or_initialize_by(label: data[:label])
        label.assign_attributes(actor_profile_id: snapshot.actor_profile_id,
          actor_behavior_snapshot_id: snapshot.id, confidence: data[:confidence],
          rule_version: @rule_version, certified_at: Time.current,
          metadata: identity.stringify_keys.merge("strict" => true,
            "reason" => data[:reason]), last_seen_at: Time.current)
        label.first_seen_at ||= Time.current
        label.save!
      end
    end

    def identity
      { cluster_id: @cluster_id, cluster_composition_version: @composition,
        profile_version: @profile_version, source_height: @height,
        source_hash: @source_hash, behavior_version: @behavior_version,
        actor_behavior_snapshot_id: @snapshot_id, rule_version: @rule_version }
    end

    def result(status, evaluation)
      { ok: true, status: status, evaluation_id: evaluation.id,
        rule_results: evaluation.rule_results }.merge(identity)
    end
    def refused(reason) = terminal("refused", reason)
    def terminal(status, reason) = { ok: status != "refused", status:, reason: }.merge(identity)
    def lock_cluster
      ActiveRecord::Base.connection.select_value(
        "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{@cluster_id})")
    end
  end
end
