# frozen_string_literal: true

module ActorBehaviors
  class SnapshotStateScope
    def self.certified_profiles
      new.certified_profiles
    end

    def self.missing_profiles
      new.missing_profiles
    end

    def self.current_profiles
      new.current_profiles
    end

    def self.stale_profiles
      new.stale_profiles
    end

    def certified_profiles
      @certified_profiles ||=
        ActorProfiles::CertifiedScope.call
    end

    def missing_profiles
      certified_profiles
        .joins(missing_join_sql)
        .where(
          "actor_behavior_snapshots.id IS NULL"
        )
    end

    def current_profiles
      certified_profiles
        .joins(snapshot_join_sql)
        .where(current_condition_sql)
    end

    def stale_profiles
      certified_profiles
        .joins(snapshot_join_sql)
        .where(stale_condition_sql)
    end

    def current_condition_sql
      <<~SQL.squish
        actor_behavior_snapshots.status = 'certified'

        AND actor_behavior_snapshots.source_hash IS NOT NULL

        AND actor_behavior_snapshots.source_hash <> ''

        AND actor_behavior_snapshots.certification_scope = 'strict'

        AND actor_behavior_snapshots.certified_at IS NOT NULL

        AND actor_behavior_snapshots.behavior_version =
            #{quoted_behavior_version}

        AND actor_behavior_snapshots.actor_profile_id =
            actor_profiles.id

        AND actor_behavior_snapshots.profile_version =
            actor_profiles.traits ->> 'profile_version'

        AND actor_behavior_snapshots.profile_height =
            actor_profiles.last_computed_height

        AND actor_behavior_snapshots.cluster_composition_version =
            actor_profiles.cluster_composition_version

        AND actor_behavior_snapshots.computed_at >=
            actor_profiles.updated_at
      SQL
    end

    def stale_condition_sql
      "NOT (#{current_condition_sql})"
    end

    private

    def missing_join_sql
      "LEFT JOIN actor_behavior_snapshots " \
        "ON actor_behavior_snapshots.cluster_id = " \
        "actor_profiles.cluster_id"
    end

    def snapshot_join_sql
      "INNER JOIN actor_behavior_snapshots " \
        "ON actor_behavior_snapshots.cluster_id = " \
        "actor_profiles.cluster_id"
    end

    def quoted_behavior_version
      ActiveRecord::Base.connection.quote(
        ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION
      )
    end
  end
end
