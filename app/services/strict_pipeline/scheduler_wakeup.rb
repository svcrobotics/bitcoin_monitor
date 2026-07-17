# frozen_string_literal: true

require "json"
require "securerandom"
require "sidekiq/api"

module StrictPipeline
  class SchedulerWakeup
    WAKEUP_KEY =
      "strict_pipeline:scheduler:wakeup_scheduled"

    PENDING_KEY =
      "strict_pipeline:scheduler:wakeup_pending"

    QUEUE_NAME =
      "scheduler"

    TARGET_CLASS =
      "StrictPipeline::SchedulerJob"

    MARKER_TTL_SECONDS =
      Integer(
        ENV.fetch(
          "STRICT_PIPELINE_SCHEDULER_WAKEUP_TTL_SECONDS",
          "300"
        )
      )

    WARNING_QUEUE_SIZE = 10
    CRITICAL_QUEUE_SIZE = 50
    STALE_ACTIVE_SECONDS = 120
    SCHEDULED_TO_ACTIVE_GRACE_SECONDS = 5

    def self.request!(
      reason:,
      wait: 0.seconds
    )
      new(
        reason: reason,
        wait: wait
      ).request!
    end

    def self.diagnostics
      new(
        reason: "diagnostics",
        wait: 0.seconds
      ).diagnostics
    end

    def self.flush_pending!
      new(
        reason: "pending_handoff",
        wait: 0.seconds
      ).flush_pending!
    end

    def initialize(reason:, wait:)
      @reason = reason.to_s
      @wait = wait
    end

    def request!
      queue_size =
        scheduler_queue_size

      log_queue_pressure(queue_size)

      if queue_size >= CRITICAL_QUEUE_SIZE
        return result(
          requested: true,
          enqueued: false,
          duplicate: false,
          blocked: true,
          reason: @reason,
          blocked_reason: "scheduler_queue_critical",
          queue_size: queue_size
        )
      end

      if active_lock_present?
        return store_pending_wakeup(
          queue_size: queue_size
        )
      end

      existing_marker =
        wakeup_marker

      if existing_marker && !scheduler_present?
        if scheduled_to_active_transition?(existing_marker)
          return duplicate_result(
            duplicate_reason: "scheduler_transition_in_progress",
            due_at: existing_marker["due_at"].to_f,
            queue_size: queue_size
          )
        end

        delete_wakeup_marker
      end

      if scheduler_present? && !wakeup_marker_present?
        return duplicate_result(
          duplicate_reason: "scheduler_already_present",
          queue_size: queue_size
        )
      end

      marker_reservation =
        reserve_wakeup_marker

      if marker_reservation[:kept]
        return duplicate_result(
          duplicate_reason: "earlier_wakeup_already_scheduled",
          due_at: marker_reservation[:current_due_at],
          queue_size: queue_size
        )
      end

      if marker_reservation[:advanced] &&
         !remove_deferred_scheduler_jobs
        return result(
          requested: true,
          enqueued: false,
          duplicate: false,
          reason: @reason,
          due_at: due_at,
          error: "deferred_scheduler_job_removal_failed",
          queue_size: queue_size
        )
      end

      job =
        enqueue_scheduler

      unless job
        delete_wakeup_marker

        return result(
          requested: true,
          enqueued: false,
          duplicate: false,
          reason: @reason,
          error: "enqueue_returned_blank",
          queue_size: queue_size
        )
      end

      result(
        requested: true,
        enqueued: true,
        duplicate: false,
        reason: @reason,
        wait_seconds: wait_seconds,
        due_at: due_at,
        job_id: job.try(:job_id),
        queue_size: queue_size
      )
    rescue StandardError => error
      delete_wakeup_marker

      Rails.logger.error(
        "[strict_pipeline_scheduler_wakeup] request_failed " \
        "reason=#{@reason.inspect} " \
        "#{error.class}: #{error.message}"
      )

      result(
        requested: true,
        enqueued: false,
        duplicate: false,
        reason: @reason,
        error_class: error.class.name,
        error_message: error.message
      )
    end

    def flush_pending!
      raw =
        redis_call(
          "GET",
          PENDING_KEY
        )

      return result(
        requested: false,
        enqueued: false,
        duplicate: false,
        reason: @reason,
        pending: false
      ) if raw.blank?

      redis_call(
        "DEL",
        PENDING_KEY
      )

      payload =
        parse_marker(raw) || {}

      pending_due_at =
        payload.fetch(
          "due_at",
          Time.current.to_f
        ).to_f

      self.class.request!(
        reason: payload.fetch("reason", "pending_handoff"),
        wait: [
          pending_due_at - Time.current.to_f,
          0
        ].max.seconds
      ).merge(
        pending_handoff: true
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler_wakeup] pending_flush_failed " \
        "#{error.class}: #{error.message}"
      )

      result(
        requested: false,
        enqueued: false,
        duplicate: false,
        reason: @reason,
        error_class: error.class.name,
        error_message: error.message
      )
    end

    def diagnostics
      marker_present =
        wakeup_marker_present?

      queued =
        scheduler_queued?

      scheduled =
        scheduler_scheduled?

      work_count =
        scheduler_work_count

      active_lock =
        active_lock_present?

      issues = []

      if active_lock &&
         active_lock_age_seconds.to_i > STALE_ACTIVE_SECONDS
        issues << {
          check: "scheduler_active_stale",
          age_seconds: active_lock_age_seconds
        }
      end

      if scheduler_queue_size > WARNING_QUEUE_SIZE
        issues << {
          check: "scheduler_queue_large",
          queue_size: scheduler_queue_size
        }
      end

      if work_count > 1
        issues << {
          check: "multiple_scheduler_jobs_active",
          active_count: work_count
        }
      end

      if marker_present && !(queued || scheduled || active_lock || work_count.positive?)
        issues << {
          check: "marker_without_scheduler_job"
        }
      end

      if !marker_present && (queued || scheduled)
        issues << {
          check: "scheduler_job_without_marker"
        }
      end

      {
        ok: issues.empty?,
        marker_present: marker_present,
        queued: queued,
        scheduled: scheduled,
        active_lock: active_lock,
        active_count: work_count,
        queue_size: scheduler_queue_size,
        issues: issues
      }
    rescue StandardError => error
      {
        ok: false,
        error_class: error.class.name,
        error_message: error.message
      }
    end

    private

    def duplicate_result(
      duplicate_reason:,
      queue_size:,
      due_at: nil
    )
      result(
        requested: true,
        enqueued: false,
        duplicate: true,
        reason: @reason,
        duplicate_reason: duplicate_reason,
        due_at: due_at,
        queue_size: queue_size
      )
    end

    def result(payload)
      payload
    end

    def scheduler_queue_size
      Sidekiq::Queue
        .new(QUEUE_NAME)
        .size
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler_wakeup] queue_size_failed " \
        "#{error.class}: #{error.message}"
      )

      0
    end

    def log_queue_pressure(queue_size)
      return if queue_size < WARNING_QUEUE_SIZE

      level =
        queue_size >= CRITICAL_QUEUE_SIZE ? :error : :warn

      Rails.logger.public_send(
        level,
        "[strict_pipeline_scheduler_wakeup] " \
        "queue_pressure queue=#{QUEUE_NAME} " \
        "size=#{queue_size} " \
        "critical=#{queue_size >= CRITICAL_QUEUE_SIZE}"
      )
    end

    def wakeup_marker_present?
      redis_call(
        "EXISTS",
        WAKEUP_KEY
      ).to_i.positive?
    end

    def wakeup_marker
      parse_marker(
        redis_call(
          "GET",
          WAKEUP_KEY
        )
      )
    end

    def scheduled_to_active_transition?(marker)
      due_at =
        marker&.fetch(
          "due_at",
          nil
        )&.to_f

      return false unless due_at

      now =
        Time.current.to_f

      due_at <= now &&
        now - due_at <= SCHEDULED_TO_ACTIVE_GRACE_SECONDS
    end

    def store_pending_wakeup(queue_size:)
      reservation =
        reserve_marker(
          PENDING_KEY
        )

      result(
        requested: true,
        enqueued: false,
        duplicate: reservation[:kept],
        reason: @reason,
        pending: true,
        duplicate_reason:
          (
            reservation[:kept] ?
              "earlier_pending_wakeup_already_recorded" :
              nil
          ),
        due_at:
          reservation[:current_due_at] || due_at,
        queue_size: queue_size
      )
    end

    def reserve_wakeup_marker
      reserve_marker(
        WAKEUP_KEY
      )
    end

    def reserve_marker(key)
      response =
        redis_call(
          "EVAL",
          reserve_marker_script,
          1,
          key,
          marker_value,
          due_at.to_s,
          MARKER_TTL_SECONDS.to_s
        )

      status =
        Array(response).first.to_s

      current =
        Array(response)[1].presence

      current_payload =
        parse_marker(current)

      {
        reserved: status == "reserved",
        kept: status == "kept",
        advanced: status == "reserved" && current.present?,
        current_due_at: current_payload&.fetch("due_at", nil)&.to_f,
        previous_marker: current_payload
      }
    end

    def reserve_marker_script
      <<~LUA
        local current = redis.call("GET", KEYS[1])

        if current then
          local ok, decoded = pcall(cjson.decode, current)

          if ok and decoded["due_at"] then
            if tonumber(decoded["due_at"]) <= tonumber(ARGV[2]) then
              return { "kept", current }
            end
          end
        end

        redis.call("SET", KEYS[1], ARGV[1], "EX", tonumber(ARGV[3]))
        return { "reserved", current or "" }
      LUA
    end

    def delete_wakeup_marker
      redis_call(
        "DEL",
        WAKEUP_KEY
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler_wakeup] marker_delete_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def marker_value
      {
        token: SecureRandom.hex(16),
        reason: @reason,
        requested_at: Time.current.iso8601(6),
        due_at: due_at
      }.to_json
    end

    def parse_marker(raw)
      return nil if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def scheduler_present?
      active_lock_present? ||
        scheduler_queued? ||
        scheduler_scheduled? ||
        scheduler_work_count.positive? ||
        active_job_test_adapter_scheduler_present?
    end

    def active_lock_present?
      redis_call(
        "EXISTS",
        StrictPipeline::SchedulerJob::ACTIVE_KEY
      ).to_i.positive?
    end

    def active_lock_age_seconds
      raw =
        redis_call(
          "GET",
          StrictPipeline::SchedulerJob::ACTIVE_STARTED_AT_KEY
        )

      return nil if raw.blank?

      Time.current.to_i - raw.to_i
    end

    def scheduler_queued?
      Sidekiq::Queue
        .new(QUEUE_NAME)
        .any? do |job|
          scheduler_job?(job.item)
        end
    end

    def scheduler_scheduled?
      Sidekiq::ScheduledSet
        .new
        .any? do |job|
          scheduler_job?(job.item)
        end
    end

    def scheduler_work_count
      Sidekiq::WorkSet
        .new
        .count do |_process_id, _thread_id, work|
          payload =
            if work.respond_to?(:payload)
              work.payload
            else
              work.to_h
            end

          scheduler_job?(payload)
        end
    end

    def scheduler_job?(payload)
      payload.to_s.include?(TARGET_CLASS)
    end

    def active_job_test_adapter_scheduler_present?
      adapter =
        StrictPipeline::SchedulerJob.queue_adapter

      return false unless
        adapter.respond_to?(:enqueued_jobs)

      adapter.enqueued_jobs.any? do |job|
        test_adapter_scheduler_job?(job)
      end
    rescue StandardError
      false
    end

    def remove_deferred_scheduler_jobs
      remove_sidekiq_deferred_scheduler_jobs &&
        remove_test_adapter_deferred_scheduler_jobs
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler_wakeup] " \
        "deferred_scheduler_job_remove_failed " \
        "#{error.class}: #{error.message}"
      )

      false
    end

    def remove_sidekiq_deferred_scheduler_jobs
      Sidekiq::ScheduledSet
        .new
        .select do |job|
          scheduler_job?(job.item)
        end
        .each(&:delete)

      true
    end

    def remove_test_adapter_deferred_scheduler_jobs
      adapter =
        StrictPipeline::SchedulerJob.queue_adapter

      return true unless
        adapter.respond_to?(:enqueued_jobs)

      adapter.enqueued_jobs.delete_if do |job|
        test_adapter_scheduler_job?(job) &&
          test_adapter_scheduled_at(job).present?
      end

      true
    end

    def test_adapter_scheduler_job?(job)
      job_class =
        if job.respond_to?(:[])
          job[:job] || job["job"]
        end

      job_class == StrictPipeline::SchedulerJob ||
        job.to_s.include?(TARGET_CLASS)
    end

    def test_adapter_scheduled_at(job)
      return nil unless job.respond_to?(:[])

      job[:at] || job["at"]
    end

    def enqueue_scheduler
      if wait_seconds.positive?
        StrictPipeline::SchedulerJob
          .set(wait: wait_seconds.seconds)
          .perform_later
      else
        StrictPipeline::SchedulerJob
          .perform_later
      end
    end

    def wait_seconds
      @wait.to_f
    end

    def due_at
      @due_at ||=
        Time.current.to_f + wait_seconds
    end

    def redis_call(*arguments)
      Sidekiq.redis do |redis|
        redis.call(*arguments)
      end
    end
  end
end
