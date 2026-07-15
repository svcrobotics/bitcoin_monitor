# frozen_string_literal: true

require "securerandom"

module Layer1
  module Audit
    class BlockJob
      include Sidekiq::Job

      sidekiq_options(
        queue: :layer1_audit,
        retry: 2
      )

      MAX_DEFER_ATTEMPTS = 5
      MIN_DEFER_DELAY = 30.seconds
      MAX_DEFER_DELAY = 15.minutes
      DEFER_KEY_PREFIX = "layer1:audit:block_job:deferred"
      DEFER_LOCK_GRACE_SECONDS = 30
      DELETE_OWNED_MARKER_SCRIPT = <<~LUA.freeze
        if redis.call("get", KEYS[1]) == ARGV[1] then
          return redis.call("del", KEYS[1])
        end
        return 0
      LUA

      def perform(height, defer_attempt = 0)
        normalized_height = normalize_non_negative_integer(height, :height)
        attempt = normalize_non_negative_integer(defer_attempt || 0, :attempt)
        decision =
          System::PipelineController.layer1_heavy_decision(:layer1_audit)

        return Layer1::AuditBlock.call(height: normalized_height) if decision[:allowed]
        return defer_exhausted_result(normalized_height, attempt, decision) if attempt >= MAX_DEFER_ATTEMPTS

        next_attempt = attempt + 1
        retry_in = capped_retry_in(decision[:retry_in])
        schedule_status =
          schedule_deferred_audit(
            height: normalized_height,
            attempt: next_attempt,
            retry_in: retry_in
          )

        result = {
          ok: true,
          status: schedule_status == :scheduled ? "deferred" : "already_scheduled",
          reason: "pipeline_controller_denied",
          height: normalized_height,
          attempt: attempt,
          next_attempt: next_attempt,
          max_attempts: MAX_DEFER_ATTEMPTS,
          scheduled_retry: schedule_status == :scheduled,
          retry_in: retry_in,
          decision: decision
        }

        Rails.logger.info(
          "[layer1_audit_block_job] #{result[:status]} " \
          "height=#{normalized_height} attempt=#{attempt} next_attempt=#{next_attempt}"
        )

        result
      end

      private

      def normalize_non_negative_integer(value, name)
        normalized = Integer(value)
        raise ArgumentError, "#{name} must be non-negative" if normalized.negative?

        normalized
      end

      def capped_retry_in(value)
        seconds = defer_delay_seconds(value)
        seconds = MIN_DEFER_DELAY.to_i if seconds < MIN_DEFER_DELAY.to_i
        seconds = MAX_DEFER_DELAY.to_i if seconds > MAX_DEFER_DELAY.to_i

        seconds.seconds
      end

      def defer_delay_seconds(value)
        return MIN_DEFER_DELAY.to_i if value.nil?

        raw_value = value.respond_to?(:to_i) ? value.to_i : value
        Integer(raw_value)
      rescue ArgumentError, TypeError
        MIN_DEFER_DELAY.to_i
      end

      def defer_exhausted_result(height, attempt, decision)
        result = {
          ok: false,
          status: "deferred_exhausted",
          reason: "pipeline_controller_denied",
          height: height,
          attempt: attempt,
          max_attempts: MAX_DEFER_ATTEMPTS,
          scheduled_retry: false,
          decision: decision
        }

        Rails.logger.warn(
          "[layer1_audit_block_job] deferred_exhausted " \
          "height=#{height} attempt=#{attempt}"
        )

        result
      end

      def schedule_deferred_audit(height:, attempt:, retry_in:)
        key = defer_marker_key(height, attempt)
        marker = SecureRandom.hex(16)
        ttl = retry_in.to_i + DEFER_LOCK_GRACE_SECONDS
        acquired = redis.set(key, marker, nx: true, ex: ttl)

        return :already_scheduled unless acquired

        begin
          self.class.perform_in(retry_in, height, attempt)
        rescue StandardError => scheduling_error
          begin
            delete_owned_marker(key, marker)
          rescue StandardError => cleanup_error
            Rails.logger.warn(
              "[layer1_audit_block_job] defer_marker_cleanup_failed " \
              "height=#{height} attempt=#{attempt} error=#{cleanup_error.class}"
            )
          end

          raise scheduling_error
        end

        :scheduled
      end

      def delete_owned_marker(key, marker)
        redis.eval(
          DELETE_OWNED_MARKER_SCRIPT,
          keys: [key],
          argv: [marker]
        )
      end

      def defer_marker_key(height, attempt)
        "#{DEFER_KEY_PREFIX}:#{height}:#{attempt}"
      end

      def redis
        @redis ||= Redis.new(
          url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
        )
      end
    end
  end
end
