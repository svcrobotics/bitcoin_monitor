# frozen_string_literal: true

module ActorBehaviors
  class StrictBatchBuilder
    DEFAULT_LIMIT = 25
    MAX_LIMIT = 500
    MISSING_RATIO = 0.72

    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    def self.normalize_limit(value)
      Integer(value)
    rescue ArgumentError, TypeError
      DEFAULT_LIMIT
    else
      [[Integer(value), 1].max, MAX_LIMIT].min
    end

    def initialize(limit: DEFAULT_LIMIT)
      @limit =
        self.class.normalize_limit(limit)
    end

    def call
      missing_quota =
        missing_quota_for(limit)

      stale_quota =
        limit - missing_quota

      missing_profiles =
        missing_scope
          .limit(missing_quota)
          .to_a

      stale_profiles =
        stale_scope
          .where.not(
            id: missing_profiles.map(&:id)
          )
          .limit(stale_quota)
          .to_a

      remaining =
        limit -
        missing_profiles.size -
        stale_profiles.size

      if remaining.positive?
        if missing_profiles.size < missing_quota
          stale_profiles +=
            stale_scope
              .where.not(
                id:
                  missing_profiles.map(&:id) +
                  stale_profiles.map(&:id)
              )
              .limit(remaining)
              .to_a
        else
          missing_profiles +=
            missing_scope
              .where.not(
                id:
                  missing_profiles.map(&:id) +
                  stale_profiles.map(&:id)
              )
              .limit(remaining)
              .to_a
        end
      end

      profiles =
        missing_profiles +
        stale_profiles

      {
        profiles: profiles,
        missing_count: missing_profiles.size,
        stale_count: stale_profiles.size,
        missing_selected: missing_profiles.size,
        stale_selected: stale_profiles.size,
        requested_limit: limit
      }
    end

    private

    attr_reader :limit

    def missing_quota_for(limit)
      return 1 if limit <= 1

      quota =
        (limit * MISSING_RATIO).round

      [[quota, 1].max, limit - 1].min
    end

    def certified_profiles
      ActorBehaviors::SnapshotStateScope
        .certified_profiles
        .includes(:cluster)
    end

    def missing_scope
      ActorBehaviors::SnapshotStateScope
        .missing_profiles
        .includes(:cluster)
        .order(
          Arel.sql(
            "actor_profiles.updated_at ASC, " \
            "actor_profiles.id ASC"
          )
        )
    end

    def stale_scope
      ActorBehaviors::SnapshotStateScope
        .stale_profiles
        .includes(:cluster)
        .order(
          Arel.sql(
            "actor_profiles.updated_at DESC, " \
            "actor_behavior_snapshots.computed_at ASC, " \
            "actor_profiles.id ASC"
          )
        )
    end
  end
end
