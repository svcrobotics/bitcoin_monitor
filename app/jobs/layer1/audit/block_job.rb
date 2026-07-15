# frozen_string_literal: true

require "securerandom"

module Layer1
  module Audit
    class BlockJob
      include Sidekiq::Job

      class EnqueueFailed < StandardError; end
      class InitialMarkerOwnershipLost < StandardError; end

      sidekiq_options(
        queue: :layer1_audit,
        retry: 2
      )

      MAX_DEFER_ATTEMPTS = 5
      MIN_DEFER_DELAY = 30.seconds
      MAX_DEFER_DELAY = 15.minutes
      INITIAL_MARKER_TTL_SECONDS = 3_600
      INITIAL_KEY_PREFIX = "layer1:audit:block_job:initial"
      DEFER_KEY_PREFIX = "layer1:audit:block_job:deferred"
      DEFER_LOCK_GRACE_SECONDS = 30
      DELETE_OWNED_MARKER_SCRIPT = <<~LUA.freeze
        if redis.call("get", KEYS[1]) == ARGV[1] then
          return redis.call("del", KEYS[1])
        end
        return 0
      LUA
      RENEW_OWNED_MARKER_SCRIPT = <<~LUA.freeze
        if redis.call("get", KEYS[1]) == ARGV[1] then
          return redis.call("expire", KEYS[1], ARGV[2])
        end
        return 0
      LUA

      class << self
        def enqueue(height:)
          normalized_height = normalize_height(height)
          token = SecureRandom.hex(16)
          connection = redis_connection
          key = initial_marker_key(normalized_height)
          acquired =
            connection.set(
              key,
              token,
              nx: true,
              ex: INITIAL_MARKER_TTL_SECONDS
            )

          unless acquired
            record_operational_event_best_effort(
              event_type: :already_enqueued,
              severity: :info,
              audited_height: normalized_height
            )
            return {
              ok: true,
              status: "already_enqueued",
              height: normalized_height,
              enqueued: false
            }
          end

          begin
            jid = perform_async(normalized_height, 0, token)
            raise EnqueueFailed, "Sidekiq did not create the Layer1 audit job" if jid.nil?
          rescue StandardError => enqueue_error
            delete_owned_initial_marker(
              connection,
              key,
              token,
              enqueue_error,
              height: normalized_height
            )
            raise enqueue_error
          end

          {
            ok: true,
            status: "enqueued",
            height: normalized_height,
            enqueued: true,
            jid: jid
          }
        end

        private

        def normalize_height(height)
          normalized = Integer(height)
          raise ArgumentError, "height must be non-negative" if normalized.negative?

          normalized
        end

        def initial_marker_key(height)
          "#{INITIAL_KEY_PREFIX}:#{height}"
        end

        def redis_connection
          Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
        end

        def delete_owned_initial_marker(connection, key, token, original_error, height:)
          connection.eval(
            DELETE_OWNED_MARKER_SCRIPT,
            keys: [key],
            argv: [token]
          )
        rescue StandardError => cleanup_error
          record_operational_event_best_effort(
            event_type: :marker_cleanup_failed,
            severity: :error,
            audited_height: height,
            error_class: cleanup_error.class.name
          )
          Rails.logger.warn(
            "[layer1_audit_block_job] initial_marker_cleanup_failed " \
            "height=#{height} error=#{cleanup_error.class} " \
            "original_error=#{original_error.class}"
          )
        end

        def record_operational_event_best_effort(event_type:, severity:, **attributes)
          Layer1::Audit::OperationalEventRecorder.call(
            event_type: event_type,
            severity: severity,
            metadata: {},
            **attributes
          )
        rescue StandardError => recorder_error
          Rails.logger.warn(
            "[layer1_audit_block_job] operational_event_recording_failed " \
            "event_type=#{event_type} recorder_error_class=#{recorder_error.class}"
          )
          nil
        end
      end

      # initial_token is optional only for jobs queued before the deduplicated
      # enqueue API existed. New producers must call .enqueue(height:).
      def perform(height, defer_attempt = 0, initial_token = nil)
        normalized_height = normalize_non_negative_integer(height, :height)
        attempt = normalize_non_negative_integer(defer_attempt || 0, :attempt)
        token = normalize_optional_token(initial_token)
        decision =
          System::PipelineController.layer1_heavy_decision(:layer1_audit)

        if decision[:allowed]
          result = Layer1::AuditBlock.call(height: normalized_height)
          release_initial_marker(normalized_height, token)
          return result
        end

        if attempt >= MAX_DEFER_ATTEMPTS
          result = defer_exhausted_result(normalized_height, attempt, decision)
          release_initial_marker(normalized_height, token, defer_attempt: attempt)
          return result
        end

        renew_initial_marker!(normalized_height, token) if token
        next_attempt = attempt + 1
        retry_in = capped_retry_in(decision[:retry_in])
        schedule_status =
          schedule_deferred_audit(
            height: normalized_height,
            attempt: next_attempt,
            retry_in: retry_in,
            initial_token: token
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

      def normalize_optional_token(value)
        return nil if value.nil?

        token = String(value)
        raise ArgumentError, "initial token must not be empty" if token.empty?

        token
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
        record_operational_event_best_effort(
          event_type: :deferred_exhausted,
          severity: :warning,
          audited_height: height,
          defer_attempt: attempt
        )

        result
      end

      def schedule_deferred_audit(height:, attempt:, retry_in:, initial_token:)
        key = defer_marker_key(height, attempt)
        marker = SecureRandom.hex(16)
        ttl = retry_in.to_i + DEFER_LOCK_GRACE_SECONDS
        acquired = redis.set(key, marker, nx: true, ex: ttl)

        return :already_scheduled unless acquired

        begin
          self.class.perform_in(retry_in, height, attempt, initial_token)
        rescue StandardError => scheduling_error
          begin
            delete_owned_marker(key, marker)
          rescue StandardError => cleanup_error
            record_operational_event_best_effort(
              event_type: :marker_cleanup_failed,
              severity: :error,
              audited_height: height,
              defer_attempt: attempt,
              error_class: cleanup_error.class.name
            )
            Rails.logger.warn(
              "[layer1_audit_block_job] defer_marker_cleanup_failed " \
              "height=#{height} attempt=#{attempt} error=#{cleanup_error.class}"
            )
          end

          raise scheduling_error
        end

        :scheduled
      end

      def renew_initial_marker!(height, token)
        renewed =
          begin
            redis.eval(
              RENEW_OWNED_MARKER_SCRIPT,
              keys: [initial_marker_key(height)],
              argv: [token, INITIAL_MARKER_TTL_SECONDS]
            )
          rescue StandardError => renewal_error
            record_operational_event_best_effort(
              event_type: :marker_renewal_failed,
              severity: :error,
              audited_height: height,
              error_class: renewal_error.class.name
            )
            raise
          end

        return if renewed.to_i.positive?

        ownership_error = InitialMarkerOwnershipLost.new(
          "Layer1 audit initial marker ownership was lost for height #{height}"
        )
        record_operational_event_best_effort(
          event_type: :initial_marker_ownership_lost,
          severity: :critical,
          audited_height: height,
          error_class: ownership_error.class.name
        )
        raise ownership_error
      end

      def release_initial_marker(height, token, defer_attempt: nil)
        return unless token

        delete_owned_marker(initial_marker_key(height), token)
      rescue StandardError => cleanup_error
        record_operational_event_best_effort(
          event_type: :marker_cleanup_failed,
          severity: :error,
          audited_height: height,
          defer_attempt: defer_attempt,
          error_class: cleanup_error.class.name
        )
        raise
      end

      def record_operational_event_best_effort(event_type:, severity:, **attributes)
        self.class.send(
          :record_operational_event_best_effort,
          event_type: event_type,
          severity: severity,
          **attributes
        )
      end

      def delete_owned_marker(key, marker)
        redis.eval(
          DELETE_OWNED_MARKER_SCRIPT,
          keys: [key],
          argv: [marker]
        )
      end

      def initial_marker_key(height)
        "#{INITIAL_KEY_PREFIX}:#{height}"
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
