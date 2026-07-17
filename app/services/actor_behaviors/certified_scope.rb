# frozen_string_literal: true

module ActorBehaviors
  class CertifiedScope
    BEHAVIOR_VERSION =
      ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION

    def self.call
      new.call
    end

    def call
      ids =
        sql_candidate_scope
          .find_each
          .filter_map do |snapshot|
            next unless fingerprint_matches?(snapshot)

            snapshot.id
          end

      ActorBehaviorSnapshot.where(id: ids)
    end

    private

    def sql_candidate_scope
      ActorBehaviorSnapshot
        .joins(:actor_profile, :cluster)
        .where(status: "certified")
        .where(behavior_version: BEHAVIOR_VERSION)
        .where(certification_scope: "strict")
        .where.not(source_hash: [nil, ""])
        .where.not(certified_at: nil)
        .where(
          "actor_behavior_snapshots.source_hash = " \
          "actor_behavior_snapshots.profile_fingerprint"
        )
        .where(
          actor_profile_id:
            ActorProfiles::CertifiedScope.call.select(:id)
        )
        .where(
          "actor_behavior_snapshots.cluster_id = " \
          "actor_profiles.cluster_id"
        )
        .where(
          "actor_behavior_snapshots.profile_version = " \
          "actor_profiles.traits ->> 'profile_version'"
        )
        .where(
          "actor_behavior_snapshots.profile_height = " \
          "actor_profiles.last_computed_height"
        )
        .where(
          "actor_behavior_snapshots.cluster_composition_version = " \
          "actor_profiles.cluster_composition_version"
        )
    end

    def fingerprint_matches?(snapshot)
      snapshot.profile_fingerprint ==
        ActorBehaviors::ProfileFingerprint.call(
          snapshot.actor_profile
        )
    end
  end
end
