# frozen_string_literal: true

require "json"
require "sidekiq/api"

module ActorLabels
  class ControlSnapshot
    QUEUE_NAME = "actor_labels_strict"
    MIN_INTERVAL_SECONDS = 60

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      cursor = current_cursor
      last_run = last_run_payload
      worker_status = worker_status_payload

      last_finished_at = parse_time(last_run["ran_at"])
      next_eligible_at =
        last_finished_at&.+(MIN_INTERVAL_SECONDS.seconds)

      cooldown_remaining =
        if next_eligible_at && now < next_eligible_at
          (next_eligible_at - now).ceil
        else
          0
        end

      {
        source: ActorLabels::StrictRuleSet::SOURCE,
        rule_version: ActorLabels::StrictRuleSet::RULE_VERSION,
        required_behavior_version:
          ActorLabels::StrictRuleSet::BEHAVIOR_VERSION,

        queue_name: QUEUE_NAME,
        queue_size: queue_size,
        scheduled_size: scheduled_size,
        worker_busy: worker_busy?,
        worker_present: worker_present?,

        worker_status: worker_status,
        worker_write_observed: worker_status.present?,
        worker_write_status_fresh:
          worker_status_fresh?(worker_status),
        worker_write_enabled:
          worker_status_fresh?(worker_status) &&
          worker_status["write_enabled"] == true,
        worker_status_observed_at:
          parse_time(worker_status["observed_at"]),

        lock_present: lock_present?,

        cursor: cursor,
        work_available: work_available?(cursor),
        pending_for_labels: pending_for_labels(cursor),

        cooldown_active: cooldown_remaining.positive?,
        cooldown_remaining_seconds: cooldown_remaining,
        next_eligible_at: next_eligible_at,

        last_run: last_run,
        last_run_status: last_run["ok"] == false ? "failed" : "completed",
        last_run_finished_at: last_finished_at,
        last_runtime_ms: last_run["runtime_ms"],

        generated_at: now
      }
    end

    private

    attr_reader :now

    def current_cursor
      Sidekiq.redis do |redis|
        redis.get(ActorLabels::StrictBatchJob::CURSOR_KEY).to_i
      end
    rescue StandardError
      0
    end

    def last_run_payload
      raw =
        Sidekiq.redis do |redis|
          redis.get(ActorLabels::StrictBatchJob::LAST_RUN_KEY)
        end

      raw.present? ? JSON.parse(raw) : {}
    rescue StandardError
      {}
    end

    def worker_status_payload
      raw =
        Sidekiq.redis do |redis|
          redis.get(
            ActorLabels::StrictBatchJob::WORKER_STATUS_KEY
          )
        end

      raw.present? ? JSON.parse(raw) : {}
    rescue StandardError
      {}
    end

    def worker_status_fresh?(payload)
      observed_at =
        parse_time(payload["observed_at"])

      return false unless observed_at

      observed_at >=
        ActorLabels::StrictBatchJob::WORKER_STATUS_TTL_SECONDS.seconds.ago
    end

    def work_available?(cursor)
      sql_current_scope
        .where(
          "actor_behavior_snapshots.id > ?",
          cursor.to_i
        )
        .exists?
    end

    def pending_for_labels(cursor)
      sql_current_scope
        .where(
          "actor_behavior_snapshots.id > ?",
          cursor.to_i
        )
        .count
    rescue StandardError
      0
    end

    def sql_current_scope
      ActorBehaviors::SnapshotStateScope
        .current_profiles
    end

    def queue_size
      Sidekiq::Queue.new(QUEUE_NAME).size
    rescue StandardError
      0
    end

    def scheduled_size
      Sidekiq::ScheduledSet.new.count { |job| job.queue == QUEUE_NAME }
    rescue StandardError
      0
    end

    def worker_busy?
      Sidekiq::Workers.new.any? do |_pid, _tid, work|
        work.instance_variable_get(:@hsh)["queue"] == QUEUE_NAME
      end
    rescue StandardError
      false
    end

    def worker_present?
      Sidekiq::ProcessSet.new.any? do |process|
        Array(process["queues"]).include?(QUEUE_NAME)
      end
    rescue StandardError
      false
    end

    def lock_present?
      Sidekiq.redis do |redis|
        value =
          redis.exists(ActorLabels::StrictBatchJob::LOCK_KEY)

        value == true || value.to_i.positive?
      end
    rescue StandardError
      false
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
