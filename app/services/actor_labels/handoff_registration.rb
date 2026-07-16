# frozen_string_literal: true

module ActorLabels
  class HandoffRegistration
    def self.call(snapshot:, rule_version: StrictRuleSetV2::RULE_VERSION)
      new(snapshot:, rule_version:).call
    end

    def initialize(snapshot:, rule_version:)
      @snapshot = snapshot
      @rule_version = rule_version.to_s
      raise ArgumentError, "rule_version must be present" if @rule_version.empty?
    end

    def call
      raise ArgumentError, "snapshot must be certified" unless
        snapshot&.persisted? && snapshot.status == "certified" &&
          snapshot.certification_scope == "strict" && snapshot.certified_at.present?

      handoff = ActorLabelHandoff.find_or_initialize_by(identity)
      created = handoff.new_record?
      handoff.save! if created
      { ok: true, status: created ? "created" : "already_registered",
        handoff_id: handoff.id }.merge(identity)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :snapshot, :rule_version

    def identity
      {
        cluster_id: snapshot.cluster_id,
        cluster_composition_version: snapshot.cluster_composition_version,
        profile_version: snapshot.profile_version,
        source_height: snapshot.profile_height,
        source_hash: snapshot.source_hash,
        behavior_version: snapshot.behavior_version,
        actor_behavior_snapshot_id: snapshot.id,
        rule_version: rule_version
      }
    end
  end
end
