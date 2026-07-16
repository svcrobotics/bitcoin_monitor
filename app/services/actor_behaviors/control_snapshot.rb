# frozen_string_literal: true

module ActorBehaviors
  class ControlSnapshot
    AUTO_ENABLED_ENV = "ACTOR_BEHAVIOR_STRICT_AUTO_ENABLED"

    def self.call(now: Time.current)
      enabled = ActiveModel::Type::Boolean.new.cast(
        ENV.fetch(AUTO_ENABLED_ENV, "true")
      ) == true
      work = BuildDispatcher.work_available?(now: now)
      stale = ActorBehaviorBuildHandoff.where(status: "processing")
        .where("claimed_at < ?", now - BuildDispatcher::STALE_AFTER).exists?

      {
        mode: "strict",
        auto_enabled: enabled,
        local_auto_enabled: enabled,
        scheduler_present: true,
        scheduler_runtime_fresh: true,
        scheduler_actor_behavior_auto_enabled: enabled,
        scheduler_enabled: true,
        behavior_version: StrictBuildFromProfile::BEHAVIOR_VERSION,
        certified_profiles_available: ActorProfiles::CertifiedScope.call.exists?,
        work_available: work,
        missing_work_available: ActorBehaviorBuildHandoff.where(status: %w[pending failed]).exists?,
        stale_work_available: stale,
        batch_running: false,
        stale_running_run: false,
        last_run_status: nil,
        last_run_finished_at: nil,
        min_interval_seconds: 0,
        last_terminal_run_finished_at: nil,
        next_eligible_at: nil,
        cooldown_active: false,
        cooldown_remaining_seconds: 0,
        generated_at: now
      }
    end
  end
end
