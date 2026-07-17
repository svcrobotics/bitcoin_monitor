# frozen_string_literal: true

require "securerandom"

module StrictPipeline
  class SchedulerJob < ApplicationJob
    queue_as :scheduler

    DEFAULT_WAIT_SECONDS = 30
    ACTIVE_KEY =
      "strict_pipeline:scheduler:active"

    ACTIVE_STARTED_AT_KEY =
      "strict_pipeline:scheduler:active_started_at"

    ACTIVE_TTL_SECONDS =
      Integer(
        ENV.fetch(
          "STRICT_PIPELINE_SCHEDULER_ACTIVE_TTL_SECONDS",
          "300"
        )
      )

    def perform
      token =
        SecureRandom.hex(16)

      unless acquire_active_lock(token)
        Rails.logger.warn(
          "[strict_pipeline_scheduler] skipped reason=already_active"
        )

        return {
          ok: true,
          status: "skipped",
          reason: "already_active"
        }
      end

      clear_wakeup_marker

      StrictPipeline::Scheduler.call

      schedule_next_once(
        reason: "periodic"
      )
    rescue StandardError => e
      Rails.logger.error(
        "[strict_pipeline_scheduler] #{e.class}: #{e.message}"
      )

      schedule_next_once(
        reason: "periodic_after_error"
      )

      raise
    ensure
      if defined?(token) && token.present?
        released =
          release_active_lock(token)

        StrictPipeline::SchedulerWakeup.flush_pending! if
          released
      end
    end

    private

    def acquire_active_lock(token)
      response =
        Sidekiq.redis do |redis|
          redis.call(
            "SET",
            ACTIVE_KEY,
            token,
            "NX",
            "EX",
            ACTIVE_TTL_SECONDS
          )
        end

      acquired =
        response == true ||
        response.to_s.upcase == "OK"

      if acquired
        Sidekiq.redis do |redis|
          redis.call(
            "SET",
            ACTIVE_STARTED_AT_KEY,
            Time.current.to_i,
            "EX",
            ACTIVE_TTL_SECONDS
          )
        end
      end

      acquired
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] active_lock_failed " \
        "#{error.class}: #{error.message}"
      )

      false
    end

    def release_active_lock(token)
      released =
        Sidekiq.redis do |redis|
        current =
          redis.call(
            "GET",
            ACTIVE_KEY
          )

        next false unless current == token

        redis.call(
          "DEL",
          ACTIVE_KEY,
          ACTIVE_STARTED_AT_KEY
        )

        true
      end

      released == true
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] active_lock_release_failed " \
        "#{error.class}: #{error.message}"
      )

      false
    end

    def clear_wakeup_marker
      Sidekiq.redis do |redis|
        redis.call(
          "DEL",
          StrictPipeline::SchedulerWakeup::WAKEUP_KEY
        )
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] wakeup_marker_clear_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def schedule_next_once(reason:)
      StrictPipeline::SchedulerWakeup.request!(
        reason: reason,
        wait: wait_seconds.seconds
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] schedule_next_failed " \
        "#{error.class}: #{error.message}"
      )

      false
    end

    def wait_seconds
      ENV
        .fetch(
          "STRICT_PIPELINE_SCHEDULER_INTERVAL_SECONDS",
          DEFAULT_WAIT_SECONDS
        )
        .to_i
    end
  end
end
