# frozen_string_literal: true

require "securerandom"

module ActorBehaviors
  class StrictBatchJob < ApplicationJob
    queue_as :actor_behavior_strict

    LOCK_KEY =
      "actor_behaviors:strict_batch:lock"

    LOCK_TTL_SECONDS =
      Integer(
        ENV.fetch(
          "ACTOR_BEHAVIOR_STRICT_LOCK_TTL_SECONDS",
          "1800"
        )
      )

    def perform(options = nil, limit: nil)
      normalized =
        normalize_options(options)

      limit_value =
        ActorBehaviors::StrictBatch.normalize_limit(
          normalized[:limit] || limit
        )

      token =
        SecureRandom.hex(16)

      lock_acquired =
        acquire_lock(token)

      unless lock_acquired
        Rails.logger.info(
          "[actor_behavior_strict_batch_job] " \
          "skipped reason=lock_busy"
        )

        return {
          ok: true,
          status: "skipped",
          reason: "lock_busy",
          limit: limit_value
        }
      end

      priority_reason =
        pipeline_priority_reason

      if priority_reason
        Rails.logger.info(
          "[actor_behavior_strict_batch_job] " \
          "deferred reason=#{priority_reason}"
        )

        return {
          ok: true,
          status: "deferred",
          reason: priority_reason.to_s,
          limit: limit_value
        }
      end

      if automatic_cooldown_enforced?(normalized) &&
         ActorBehaviors::ControlSnapshot.call[:cooldown_active] == true
        Rails.logger.info(
          "[actor_behavior_strict_batch_job] " \
          "skipped reason=actor_behavior_cooldown"
        )

        return {
          ok: true,
          status: "skipped",
          reason: "actor_behavior_cooldown",
          limit: limit_value
        }
      end

      result =
        ActorBehaviors::StrictBatch.call(
          limit: limit_value,
          trigger: "job",
          cooperative_guard:
            -> { pipeline_priority_reason }
        )

      Rails.logger.info(
        "[actor_behavior_strict_batch_job] " \
        "done selected=#{result[:selected]} " \
        "created=#{result[:created]} " \
        "updated=#{result[:updated]} " \
        "unchanged=#{result[:unchanged]} " \
        "deferred=#{result[:deferred]} " \
        "failed=#{result[:failed]}"
      )

      result.merge(
        automation: {
          queue: self.class.queue_name,
          limit: limit_value,
          lock_key: LOCK_KEY
        }
      )
    ensure
      if defined?(lock_acquired) &&
         lock_acquired &&
         defined?(token) &&
         token.present?
        release_lock(token)
      end
    end

    private

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
        !!redis.set(
          LOCK_KEY,
          token,
          nx: true,
          ex: LOCK_TTL_SECONDS
        )
      end
    end

    def automatic_cooldown_enforced?(options)
      ActiveModel::Type::Boolean.new.cast(
        options[:enforce_cooldown]
      )
    end

    def pipeline_priority_reason
      System::PipelineController
        .downstream_preemption_reason(
          :actor_behavior
        )
    end

    def release_lock(token)
      Sidekiq.redis do |redis|
        redis.del(LOCK_KEY) if redis.get(LOCK_KEY) == token
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_behavior_strict_batch_job] " \
        "lock_release_failed " \
        "#{error.class}: #{error.message}"
      )
    end
  end
end
