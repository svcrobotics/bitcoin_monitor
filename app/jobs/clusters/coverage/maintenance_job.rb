# frozen_string_literal: true

require "securerandom"

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

        clear_schedule_marker

        return disabled_result unless enabled?

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
        if defined?(reschedule) &&
           reschedule &&
           enabled?
          wait =
            if defined?(decision) && decision.is_a?(Hash)
              decision[:retry_in] || wait_seconds.seconds
            else
              wait_seconds.seconds
            end

          schedule_next_once(wait: wait)
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

      def schedule_next_once(wait: wait_seconds.seconds)
        scheduled =
          Sidekiq.redis do |redis|
            redis.set(
              SCHEDULE_KEY,
              Process.pid,
              nx: true,
              ex: wait.to_i + 600
            )
          end

        return false unless scheduled

        self.class
          .set(wait: wait)
          .perform_later(
            {
              "reschedule" => true,
              "lock" => true
            }
          )

        Rails.logger.info(
          "[cluster_coverage_maintenance] " \
          "next_scheduled wait=#{wait.to_i}s"
        )

        true
      rescue StandardError => error
        Sidekiq.redis do |redis|
          redis.del(SCHEDULE_KEY)
        end

        Rails.logger.error(
          "[cluster_coverage_maintenance] " \
          "schedule_next_failed " \
          "#{error.class}: #{error.message}"
        )

        raise
      end

      def clear_schedule_marker
        Sidekiq.redis do |redis|
          redis.del(SCHEDULE_KEY)
        end
      rescue StandardError => error
        Rails.logger.warn(
          "[cluster_coverage_maintenance] " \
          "schedule_marker_clear_failed " \
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
    end
  end
end
