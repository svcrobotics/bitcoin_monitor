# frozen_string_literal: true

module ActorBehaviors
  class StrictHealthSnapshot
    PHASE = "shadow"

    def self.call(operational: nil)
      new(
        operational: operational
      ).call
    end

    def initialize(operational: nil)
      @operational =
        operational
    end

    def call
      operational =
        self.operational ||
        ActorBehaviors::OperationalSnapshot.call

      reasons =
        reasons_for(operational)

      status =
        status_for(operational)

      {
        status: status,
        phase: PHASE,
        ready: status == "shadow_ready",
        reasons: reasons,
        operational: operational,
        generated_at: Time.current
      }
    end

    private

    attr_reader :operational

    def status_for(operational)
      certified =
        operational[:actor_profiles_certified].to_i

      current =
        operational[:snapshots_current].to_i

      missing =
        operational[:snapshots_missing].to_i

      stale =
        operational[:snapshots_stale].to_i

      return "shadow_empty" if certified.zero?
      return "shadow_empty" if current.zero? &&
                               stale.zero?

      if missing.positive? ||
         stale.positive?
        return "shadow_building"
      end

      if current == certified
        return "shadow_ready"
      end

      "shadow_building"
    end

    def reasons_for(operational)
      reasons = []

      certified =
        operational[:actor_profiles_certified].to_i

      current =
        operational[:snapshots_current].to_i

      missing =
        operational[:snapshots_missing].to_i

      stale =
        operational[:snapshots_stale].to_i

      non_certified =
        operational[:snapshots_non_certified_status].to_i

      if certified.zero?
        reasons << "no_certified_actor_profiles"
      elsif current.zero? &&
            stale.zero?
        reasons << "no_behavior_snapshots"
      end

      if missing.positive? ||
         stale.positive?
        reasons << "behavior_backfill_in_progress"
      end

      reasons << "missing_behavior_snapshots" if missing.positive?
      reasons << "stale_behavior_snapshots" if stale.positive?

      if non_certified.positive?
        reasons << "non_certified_snapshot_statuses"
      end

      if missing.zero? &&
         operational[:checkpoint_lag].to_i.positive?
        reasons << "behavior_checkpoint_lag"
      end

      if behavior_version_mismatch?(operational)
        reasons << "behavior_version_mismatch"
      end

      reasons.uniq
    end

    def behavior_version_mismatch?(operational)
      versions =
        operational[:behavior_versions].to_h

      current =
        operational[:behavior_version].to_s

      versions.any? do |version, count|
        version.to_s != current &&
          count.to_i.positive?
      end
    end
  end
end
