# frozen_string_literal: true

require "json"

module ActorBehaviors
  class ControlSnapshot
    MODE = "shadow"
    AUTO_ENABLED_ENV = "ACTOR_BEHAVIOR_AUTO_ENABLED"
    MIN_INTERVAL_ENV = "ACTOR_BEHAVIOR_MIN_INTERVAL_SECONDS"
    DEFAULT_MIN_INTERVAL_SECONDS = 60
    MIN_INTERVAL_SECONDS = 10
    MAX_INTERVAL_SECONDS = 3_600
    TERMINAL_RUN_STATUSES = %w[
      completed
      completed_with_errors
      failed
    ].freeze
    SCHEDULER_RUNTIME_FRESH_AFTER_SECONDS = 180

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
      @snapshot_state_scope =
        ActorBehaviors::SnapshotStateScope.new
    end

    def call
      missing =
        missing_work_available?

      stale =
        stale_work_available?

      last_run =
        latest_run

      last_terminal_run =
        latest_terminal_run

      min_interval_seconds =
        resolved_min_interval_seconds
      scheduler_runtime =
        scheduler_runtime_status
      scheduler_observed_at =
        parse_time(scheduler_runtime["observed_at"])
      scheduler_fresh =
        scheduler_observed_at.present? &&
        scheduler_observed_at >=
          SCHEDULER_RUNTIME_FRESH_AFTER_SECONDS.seconds.ago
      local_auto_enabled =
        local_auto_enabled?
      scheduler_auto_enabled =
        scheduler_runtime["actor_behavior_auto_enabled"] == true

      last_terminal_run_finished_at =
        last_terminal_run&.finished_at

      next_eligible_at =
        if last_terminal_run_finished_at.present?
          last_terminal_run_finished_at + min_interval_seconds.seconds
        end

      cooldown_remaining_seconds =
        remaining_seconds(next_eligible_at)

      {
        mode: MODE,
        auto_enabled:
          scheduler_fresh ? scheduler_auto_enabled : local_auto_enabled,
        local_auto_enabled: local_auto_enabled,
        scheduler_runtime: scheduler_runtime,
        scheduler_observed_at: scheduler_observed_at,
        scheduler_runtime_fresh: scheduler_fresh,
        scheduler_present: scheduler_runtime.present?,
        scheduler_actor_behavior_auto_enabled:
          scheduler_auto_enabled,
        scheduler_enabled:
          scheduler_runtime["scheduler_enabled"] == true,
        behavior_version:
          ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,

        certified_profiles_available:
          certified_profiles_available?,

        work_available:
          missing || stale,

        missing_work_available:
          missing,

        stale_work_available:
          stale,

        batch_running:
          batch_running?,

        stale_running_run:
          stale_running_run?,

        last_run_status:
          last_run&.status,

        last_run_finished_at:
          last_run&.finished_at,

        min_interval_seconds:
          min_interval_seconds,

        last_terminal_run_finished_at:
          last_terminal_run_finished_at,

        next_eligible_at:
          next_eligible_at,

        cooldown_active:
          cooldown_remaining_seconds.positive?,

        cooldown_remaining_seconds:
          cooldown_remaining_seconds,

        generated_at:
          @now
      }
    end

    private

    attr_reader :snapshot_state_scope

    def local_auto_enabled?
      ActiveModel::Type::Boolean
        .new
        .cast(
          ENV.fetch(AUTO_ENABLED_ENV, "false")
        ) == true
    end

    def resolved_min_interval_seconds
      value =
        Integer(
          ENV.fetch(
            MIN_INTERVAL_ENV,
            DEFAULT_MIN_INTERVAL_SECONDS.to_s
          ),
          10
        )

      return DEFAULT_MIN_INTERVAL_SECONDS unless value.between?(
        MIN_INTERVAL_SECONDS,
        MAX_INTERVAL_SECONDS
      )

      value
    rescue ArgumentError, TypeError
      DEFAULT_MIN_INTERVAL_SECONDS
    end

    def remaining_seconds(next_eligible_at)
      return 0 if next_eligible_at.blank?

      [
        (next_eligible_at - @now).ceil,
        0
      ].max
    end

    def certified_profiles_available?
      snapshot_state_scope
        .certified_profiles
        .exists?
    end

    def missing_work_available?
      snapshot_state_scope
        .missing_profiles
        .exists?
    end

    def stale_work_available?
      snapshot_state_scope
        .stale_profiles
        .exists?
    end

    def batch_running?
      ActorBehaviorRun
        .running
        .where(
          "started_at >= ?",
          ActorBehaviorRun::STALE_RUNNING_AFTER.ago
        )
        .exists?
    end

    def stale_running_run?
      ActorBehaviorRun
        .stale_running
        .exists?
    end

    def latest_run
      ActorBehaviorRun
        .order(started_at: :desc, id: :desc)
        .limit(1)
        .first
    end

    def latest_terminal_run
      ActorBehaviorRun
        .where(status: TERMINAL_RUN_STATUSES)
        .where.not(finished_at: nil)
        .order(finished_at: :desc, id: :desc)
        .limit(1)
        .first
    end

    def scheduler_runtime_status
      raw =
        Sidekiq.redis do |redis|
          redis.get(StrictPipeline::Scheduler::RUNTIME_STATUS_KEY)
        end

      raw.present? ? JSON.parse(raw) : {}
    rescue StandardError
      {}
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
