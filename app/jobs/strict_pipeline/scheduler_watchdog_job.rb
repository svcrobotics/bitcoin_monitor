# frozen_string_literal: true

module StrictPipeline
  class SchedulerWatchdogJob < ApplicationJob
    queue_as :scheduler

    LOCK_NAMESPACE = 41_023
    LOCK_ID = 1

    def perform
      return locked_result unless acquire_scheduler_lock

      StrictPipeline::SchedulerWatchdog.call
    rescue StandardError => error
      @watchdog_error = error
      raise
    ensure
      release_scheduler_lock_without_masking if @scheduler_lock_acquired
    end

    private

    def acquire_scheduler_lock
      value = ApplicationRecord.connection.select_value(
        "SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{LOCK_ID})"
      )
      @scheduler_lock_acquired = value == true || value.to_s == "t"
    end

    def release_scheduler_lock
      ApplicationRecord.connection.select_value(
        "SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{LOCK_ID})"
      )
      @scheduler_lock_acquired = false
    end

    def release_scheduler_lock_without_masking
      release_scheduler_lock
    rescue StandardError => unlock_error
      raise unlock_error unless @watchdog_error

      Rails.logger.error(
        "[strict_pipeline_scheduler_watchdog_job] unlock_failed " \
        "error_class=#{unlock_error.class.name}"
      )
    end

    def locked_result
      { ok: true, skipped: true, reason: "scheduler_lock_held" }
    end
  end
end
