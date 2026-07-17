# frozen_string_literal: true

require "securerandom"

module Clusters
  class StrictTipSyncJob < ApplicationJob
    queue_as :cluster_strict


    DEFAULT_WAIT_SECONDS = 30
    DEFAULT_LIMIT = 2
    MAX_SLICE_BLOCKS = 2
    MAX_SLICE_SECONDS = 90

    LOCK_KEY =
      "clusters:strict_tip_sync_job:lock"

    SCHEDULE_KEY =
      "clusters:strict_tip_sync_job:scheduled"

    LOCK_TTL_SECONDS =
      Integer(
        ENV.fetch(
          "CLUSTER_STRICT_JOB_LOCK_TTL_SECONDS",
          "3600"
        )
      )

    def perform(
      options = nil,
      limit: nil,
      reschedule: true
    )
      scheduler_wakeup_requested = false

      normalized =
        normalize_options(options)

      continuous_reschedule =
        ActiveModel::Type::Boolean.new.cast(
          normalized.key?(:reschedule) ?
            normalized[:reschedule] :
            reschedule
        )

      strict_io_token =
        normalized[:strict_io_token].presence

      unless strict_io_token.present? &&
             StrictPipeline::StrictIoLease.renew(
               owner: "cluster",
               token: strict_io_token
             )
        Rails.logger.info(
          "[cluster_strict_tip_sync_job] " \
          "skipped reason=strict_io_lease_denied"
        )

        request_scheduler_wakeup_once(
          reason: "cluster_strict_io_lease_denied",
          wait: 30.seconds
        )
        scheduler_wakeup_requested = true

        return {
          ok: true,
          status: "skipped",
          reason: "strict_io_lease_denied"
        }
      end

      limit_value =
        [
          integer_option(
            normalized[:limit] || limit,
            default:
              Integer(
                ENV.fetch(
                  "CLUSTER_STRICT_SYNC_LIMIT",
                  DEFAULT_LIMIT.to_s
                )
              ),
            minimum: 1,
            maximum: 100
          ),
          MAX_SLICE_BLOCKS
        ].min

      token =
        SecureRandom.hex(16)

      lock_acquired =
        acquire_lock(token)

      unless lock_acquired
        request_scheduler_wakeup_once(
          reason: "cluster_job_locked",
          wait: 30.seconds
        )
        scheduler_wakeup_requested = true

        Rails.logger.info(
          "[cluster_strict_tip_sync_job] " \
          "skipped reason=job_locked " \
          "scheduled_next=false"
        )

        return {
          ok: true,
          status: "skipped",
          reason: "job_locked",
          scheduled_next: false
        }
      end

      # Le marqueur représentait le job qui vient
      # effectivement de commencer.
      clear_schedule_marker

      decision =
        System::PipelineController.decision(:cluster)

      unless decision[:allowed]
        retry_in =
          decision[:retry_in] || wait_seconds.seconds

        request_scheduler_wakeup_once(
          reason: "cluster_pipeline_controller_denied",
          wait: retry_in
        )
        scheduler_wakeup_requested = true

        Rails.logger.info(
          "[cluster_strict_tip_sync_job] " \
          "skipped reason=pipeline_controller_denied " \
          "decision=#{decision.inspect} " \
          "retry_in=#{retry_in.to_i}s " \
          "scheduled_next=false"
        )

        return {
          ok: true,
          status: "skipped",
          reason: "pipeline_controller_denied",
          decision: decision,
          retry_in: retry_in,
          scheduled_next: false
        }
      end

      result =
        Clusters::StrictTipSyncer.call(
          limit: limit_value,
          max_runtime_seconds: MAX_SLICE_SECONDS,
          yield_guard:
            lambda do |_height|
              if StrictPipeline::StrictIoLease.renew(
                owner: "cluster",
                token: strict_io_token
              )
                System::PipelineController.decision(:cluster)
              else
                {
                  allowed: false,
                  reason: :strict_io_lease_denied,
                  failed_constraints: [:strict_io_not_layer1]
                }
              end
            end
        )

      unless result[:ok]
        raise(
          "Cluster strict tip sync failed " \
          "status=#{result[:status]} " \
          "message=#{result[:message]}"
        )
      end

      # Ne pas réveiller le scheduler ici.
      #
      # Le verrou du job et le lease strict_io sont encore détenus.
      # Le bloc ensure les libère d'abord, puis demande immédiatement
      # le prochain passage du scheduler.
      Rails.logger.info(
        "[cluster_strict_tip_sync_job] " \
        "done status=#{result[:status]} " \
        "from_height=#{result[:from_height]} " \
        "to_height=#{result[:to_height]} " \
        "continuous_reschedule=#{continuous_reschedule} " \
        "scheduler_wakeup=after_release"
      )

      result.merge(
        automation: {
          queue: self.class.queue_name,
          limit: limit_value,
          reschedule: continuous_reschedule,
          scheduled_next: false,
          scheduler_wakeup_after_release: true,
          scheduler_wakeup_wait_seconds: 0,
          wait_seconds: wait_seconds
        }
      )
    rescue StandardError
      unless defined?(scheduler_wakeup_requested) &&
             scheduler_wakeup_requested
        request_scheduler_wakeup_once(
          reason: "cluster_failed",
          wait: 30.seconds
        )
        scheduler_wakeup_requested = true
      end

      raise
    ensure
      if defined?(lock_acquired) &&
         lock_acquired &&
         defined?(token) &&
         token.present?
        release_lock(token)
      end

      if defined?(strict_io_token) && strict_io_token.present?
        StrictPipeline::StrictIoLease.release(
          owner: "cluster",
          token: strict_io_token
        )
      end

      if defined?(scheduler_wakeup_requested) &&
         !scheduler_wakeup_requested
        request_scheduler_wakeup_once(
          reason: "cluster_finished"
        )
      end
    end

    private

    def request_scheduler_wakeup_once(
      reason:,
      wait: 0.seconds
    )
      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: reason,
          wait: wait
        )

      Rails.logger.info(
        "[cluster_strict_tip_sync_job] " \
        "scheduler_wakeup " \
        "reason=#{reason} " \
        "wait_seconds=#{wait.to_f} " \
        "result=#{result.inspect}"
      )

      result
    end

    def normalize_options(options)
      return {} unless options.is_a?(Hash)

      if options.respond_to?(:with_indifferent_access)
        options.with_indifferent_access
      else
        options
      end
    end

    def acquire_lock(token)
      Sidekiq.redis do |redis|
        result =
          redis.set(
            LOCK_KEY,
            token,
            nx: true,
            ex: LOCK_TTL_SECONDS
          )

        result == true || result == "OK"
      end
    end

    def release_lock(token)
      Sidekiq.redis do |redis|
        redis.del(LOCK_KEY) if redis.get(LOCK_KEY) == token
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[cluster_strict_tip_sync_job] " \
        "lock_release_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def clear_schedule_marker
      Sidekiq.redis do |redis|
        redis.del(SCHEDULE_KEY)
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[cluster_strict_tip_sync_job] " \
        "schedule_marker_clear_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def wait_seconds
      integer_option(
        ENV.fetch(
          "CLUSTER_STRICT_WAIT_SECONDS",
          DEFAULT_WAIT_SECONDS.to_s
        ),
        default: DEFAULT_WAIT_SECONDS,
        minimum: 10,
        maximum: 3_600
      )
    end

    def integer_option(
      value,
      default:,
      minimum:,
      maximum:
    )
      integer =
        Integer(value || default)

      [
        [integer, minimum].max,
        maximum
      ].min
    rescue ArgumentError, TypeError
      default
    end


  end
end
