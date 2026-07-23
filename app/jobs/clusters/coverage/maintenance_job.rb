# frozen_string_literal: true

require "securerandom"
require "json"

module Clusters
  module Coverage
    class MaintenanceJob < ApplicationJob
      queue_as :cluster_coverage

      ENABLED_ENV =
        "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"

      LOCK_KEY =
        "cluster_coverage:maintenance:lock"

      SCHEDULE_KEY =
        "cluster_coverage:maintenance:scheduled"

      DEFAULT_WAIT_SECONDS = 120
      DEFAULT_LOCK_TTL_SECONDS = 3_600
      SCHEDULE_MARKER_GRACE_SECONDS = 600

      class << self
        def schedule_key
          SCHEDULE_KEY
        end

        def enqueue_once(wait: 0.seconds, source: "startup")
          return duplicate_schedule_result if pending_maintenance_job?

          marker = "scheduled:#{SecureRandom.hex(16)}"
          ttl = wait.to_i + SCHEDULE_MARKER_GRACE_SECONDS

          reserved =
            Sidekiq.redis do |redis|
              redis.set(
                schedule_key,
                marker,
                nx: true,
                ex: ttl
              )
            end

          return duplicate_schedule_result unless reserved

          enqueue_reserved(
            wait: wait,
            marker: marker,
            source: source
          )
        end

        def reschedule_once(wait:, owner_marker:)
          marker = "scheduled:#{SecureRandom.hex(16)}"
          ttl = wait.to_i + SCHEDULE_MARKER_GRACE_SECONDS

          reserved =
            replace_owned_marker(
              owner_marker,
              marker,
              ttl
            )

          return duplicate_schedule_result unless reserved

          enqueue_reserved(
            wait: wait,
            marker: marker,
            source: "job"
          )
        end

        def claim_execution(schedule_token:, execution_marker:, job_id:)
          if schedule_token.blank? &&
             pending_maintenance_job?(exclude_job_id: job_id)
            return false
          end

          Sidekiq.redis do |redis|
            redis.call(
              "EVAL",
              claim_execution_script,
              1,
              schedule_key,
              schedule_token.to_s,
              execution_marker,
              DEFAULT_LOCK_TTL_SECONDS
            )
          end.to_i.positive?
        end

        def release_owned_marker(marker)
          Sidekiq.redis do |redis|
            redis.call(
              "EVAL",
              delete_owned_marker_script,
              1,
              schedule_key,
              marker
            )
          end
        end

        def pending_maintenance_job?(exclude_job_id: nil)
          require "sidekiq/api"

          queue = Sidekiq::Queue.new(queue_name)
          scheduled = Sidekiq::ScheduledSet.new
          retries = Sidekiq::RetrySet.new

          return true if queue.any? { |job| maintenance_job?(job.item) }
          return true if scheduled.any? { |job| maintenance_job?(job.item) }
          return true if retries.any? { |job| maintenance_job?(job.item) }

          Sidekiq::WorkSet.new.any? do |_process_id, _thread_id, work|
            payload =
              work.respond_to?(:payload) ?
                work.payload :
                work.to_h

            maintenance_job?(payload) &&
              (
                exclude_job_id.blank? ||
                payload_job_id(payload) != exclude_job_id
              )
          end
        rescue StandardError => error
          Rails.logger.warn(
            "[cluster_coverage_maintenance] " \
            "pending_check_failed " \
            "#{error.class}: #{error.message}"
          )

          false
        end

        private

        def enqueue_reserved(wait:, marker:, source:)
          scheduled_at = Time.current + wait

          job =
            set(wait: wait)
              .perform_later(
                {
                  "reschedule" => true,
                  "lock" => true,
                  "schedule_token" => marker
                }
              )

          raise "maintenance enqueue returned no job" if job.blank?

          Rails.logger.info(
            "[cluster_coverage_maintenance] " \
            "rescheduled=true retry_in=#{wait.to_i} " \
            "scheduled_at=#{scheduled_at.iso8601(6)} " \
            "source=#{source}"
          )

          {
            rescheduled: true,
            retry_in: wait.to_i,
            scheduled_at: scheduled_at,
            job: job
          }
        rescue StandardError => error
          release_owned_marker(marker)

          Rails.logger.error(
            "[cluster_coverage_maintenance] " \
            "schedule_next_failed " \
            "#{error.class}: #{error.message}"
          )

          raise
        end

        def duplicate_schedule_result
          Rails.logger.info(
            "[cluster_coverage_maintenance] " \
            "rescheduled=false reason=already_scheduled"
          )

          {
            rescheduled: false,
            reason: "already_scheduled"
          }
        end

        def replace_owned_marker(owner_marker, marker, ttl)
          Sidekiq.redis do |redis|
            redis.call(
              "EVAL",
              replace_owned_marker_script,
              1,
              schedule_key,
              owner_marker,
              marker,
              ttl
            )
          end.to_i.positive?
        end

        def maintenance_job?(payload)
          payload =
            normalize_sidekiq_payload(payload)

          return false unless payload

          active_job =
            active_job_payload(payload)

          [
            payload["wrapped"],
            payload["class"],
            payload["job_class"],
            active_job["job_class"]
          ].compact.any? do |job_class|
            job_class.to_s == name
          end
        end

        def payload_job_id(payload)
          payload =
            normalize_sidekiq_payload(payload)

          return nil unless payload

          payload["job_id"] ||
            active_job_payload(payload)["job_id"]
        end

        def normalize_sidekiq_payload(payload)
          case payload
          when Hash
            payload.stringify_keys
          when String
            JSON.parse(payload)
          end
        rescue JSON::ParserError
          nil
        end

        def active_job_payload(payload)
          first_argument =
            Array(payload["args"]).first

          first_argument.is_a?(Hash) ?
            first_argument.stringify_keys :
            {}
        end

        def claim_execution_script
          <<~LUA
            local current = redis.call("GET", KEYS[1])
            local expected = ARGV[1]

            if expected ~= "" then
              if current and current ~= expected then
                return 0
              end
            elseif current then
              if string.sub(current, 1, 10) == "scheduled:" or
                 string.sub(current, 1, 7) == "active:" then
                return 0
              end
            end

            redis.call("SET", KEYS[1], ARGV[2], "EX", tonumber(ARGV[3]))
            return 1
          LUA
        end

        def replace_owned_marker_script
          <<~LUA
            if redis.call("GET", KEYS[1]) ~= ARGV[1] then
              return 0
            end

            redis.call("SET", KEYS[1], ARGV[2], "EX", tonumber(ARGV[3]))
            return 1
          LUA
        end

        def delete_owned_marker_script
          <<~LUA
            if redis.call("GET", KEYS[1]) ~= ARGV[1] then
              return 0
            end

            return redis.call("DEL", KEYS[1])
          LUA
        end
      end

      def perform(options = {})
        options =
          options.to_h.with_indifferent_access

        reschedule =
          boolean_value(
            options.fetch(:reschedule, true)
          )

        use_lock =
          boolean_value(
            options.fetch(:lock, true)
          )

        unless enabled?
          schedule_token =
            options[:schedule_token]

          self.class.release_owned_marker(
            schedule_token
          ) if schedule_token.present?

          return disabled_result
        end

        execution_marker =
          "active:#{job_id}:#{SecureRandom.hex(8)}"

        schedule_claimed =
          self.class.claim_execution(
            schedule_token: options[:schedule_token],
            execution_marker: execution_marker,
            job_id: job_id
          )

        return already_scheduled_result unless schedule_claimed

        decision =
          System::PipelineController.decision(:coverage)

        return pipeline_denied_result(decision) unless decision[:allowed]

        result =
          if use_lock
            with_lock { run_cycle }
          else
            run_cycle
          end

        result
      ensure
        if defined?(schedule_claimed) &&
           schedule_claimed &&
           defined?(reschedule) &&
           reschedule &&
           enabled?
          wait =
            if defined?(decision) && decision.is_a?(Hash)
              decision[:retry_in] || wait_seconds.seconds
            else
              wait_seconds.seconds
            end

          self.class.reschedule_once(
            wait: wait,
            owner_marker: execution_marker
          )
        elsif defined?(schedule_claimed) &&
              schedule_claimed &&
              defined?(execution_marker)
          self.class.release_owned_marker(
            execution_marker
          )
        end
      end

      private

      def run_cycle
        started_at =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )

        backfill =
          Clusters::Coverage::InputAddressBackfill.call(
            window_blocks:
              integer_env(
                "CLUSTER_COVERAGE_BACKFILL_WINDOW_BLOCKS",
                100
              ),

            batch_size:
              integer_env(
                "CLUSTER_COVERAGE_BACKFILL_BATCH_SIZE",
                1_000
              ),

            lock: true
          )

        normal =
          Clusters::Coverage::AddressRunner.call(
            batch_size:
              integer_env(
                "CLUSTER_COVERAGE_ADDRESS_BATCH_SIZE",
                1_000
              ),

            max_batches:
              integer_env(
                "CLUSTER_COVERAGE_ADDRESS_MAX_BATCHES",
                20
              ),

            reconcile: false,
            lock: true
          )

        reconciliation =
          Clusters::Coverage::AddressRunner.call(
            batch_size:
              integer_env(
                "CLUSTER_COVERAGE_RECONCILE_BATCH_SIZE",
                1_000
              ),

            max_batches:
              integer_env(
                "CLUSTER_COVERAGE_RECONCILE_MAX_BATCHES",
                5
              ),

            reconcile: true,
            lock: true
          )

        health =
          Clusters::Coverage::AddressHealthSnapshot.call

        coverage =
          Clusters::Coverage::OperationalSnapshot.refresh(
            from_height:
              backfill.fetch(:from_height),

            to_height:
              backfill.fetch(:to_height)
          )

        duration_seconds =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) - started_at

        ok =
          backfill[:ok] == true &&
          normal[:ok] == true &&
          reconciliation[:ok] == true &&
          coverage[:complete] == true

        result = {
          ok: ok,
          status: ok ? "completed" : "warning",
          backfill: backfill,
          address_runner: normal,
          reconciliation: reconciliation,
          health: health,
          coverage: coverage,
          duration_ms:
            (duration_seconds * 1_000).round,
          duration_seconds:
            duration_seconds.round(3),
          completed_at: Time.current
        }

        Rails.logger.info(
          "[cluster_coverage_maintenance] " \
          "ok=#{ok} " \
          "backfilled=#{backfill[:addresses_upserted]} " \
          "singletons=#{normal[:singleton_clusters_created]} " \
          "reconciled=#{reconciliation[:singleton_clusters_created]} " \
          "address_lag=#{health[:address_id_lag]} " \
          "null_after=#{health[:null_addresses_after_cursor]} " \
          "duration_s=#{duration_seconds.round(3)}"
        )

        result
      end

      def with_lock
        token =
          SecureRandom.hex(16)

        acquired =
          Sidekiq.redis do |redis|
            redis.set(
              LOCK_KEY,
              token,
              nx: true,
              ex: lock_ttl_seconds
            )
          end

        unless acquired
          return {
            ok: true,
            status: "locked",
            reason: "maintenance_already_running",
            completed_at: Time.current
          }
        end

        yield
      ensure
        if defined?(token) && token.present?
          release_lock(token)
        end
      end

      def release_lock(token)
        Sidekiq.redis do |redis|
          redis.del(LOCK_KEY) if redis.get(LOCK_KEY) == token
        end
      rescue StandardError => error
        Rails.logger.warn(
          "[cluster_coverage_maintenance] " \
          "lock_release_failed " \
          "#{error.class}: #{error.message}"
        )
      end

      def enabled?
        ActiveModel::Type::Boolean
          .new
          .cast(
            ENV.fetch(
              ENABLED_ENV,
              "false"
            )
          )
      end

      def disabled_result
        {
          ok: true,
          status: "disabled",
          enabled: false,
          completed_at: Time.current
        }
      end

      def wait_seconds
        [
          integer_env(
            "CLUSTER_COVERAGE_MAINTENANCE_WAIT_SECONDS",
            DEFAULT_WAIT_SECONDS
          ),
          30
        ].max
      end

      def lock_ttl_seconds
        [
          integer_env(
            "CLUSTER_COVERAGE_MAINTENANCE_LOCK_TTL_SECONDS",
            DEFAULT_LOCK_TTL_SECONDS
          ),
          300
        ].max
      end

      def integer_env(name, default)
        [
          ENV.fetch(name, default).to_i,
          1
        ].max
      end

      def boolean_value(value)
        ActiveModel::Type::Boolean
          .new
          .cast(value)
      end

      def pipeline_denied_result(decision)
        Rails.logger.info(
          "[cluster_coverage_maintenance] " \
          "skipped reason=pipeline_controller_denied " \
          "decision=#{decision.inspect}"
        )

        {
          ok: true,
          status: "skipped",
          reason: "pipeline_controller_denied",
          decision: decision
        }
      end

      def already_scheduled_result
        Rails.logger.info(
          "[cluster_coverage_maintenance] " \
          "skipped reason=already_scheduled " \
          "rescheduled=false"
        )

        {
          ok: true,
          status: "skipped",
          reason: "already_scheduled"
        }
      end
    end
  end
end
