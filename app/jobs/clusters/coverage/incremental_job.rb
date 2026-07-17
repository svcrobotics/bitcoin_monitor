# frozen_string_literal: true

require "securerandom"
require "sidekiq/api"

module Clusters
  module Coverage
    class IncrementalJob < ApplicationJob
      queue_as :cluster_coverage

      ENABLED_ENV =
        "CLUSTER_COVERAGE_INCREMENTAL_ENABLED"

      LOCK_KEY =
        "cluster_coverage:incremental:lock"

      LOCK_TTL_SECONDS =
        Integer(
          ENV.fetch(
            "CLUSTER_COVERAGE_LOCK_TTL_SECONDS",
            "600"
          )
        )

      DEFAULT_BATCH_SIZE =
        Clusters::Coverage::ProcessPage::DEFAULT_BATCH_SIZE

      def perform(
        height: nil,
        batch_size: DEFAULT_BATCH_SIZE
      )
        return disabled_result unless enabled?

        decision =
          System::PipelineController.decision(:coverage)

        return pipeline_denied_result(decision) unless decision[:allowed]

        with_lock do
          prepared =
            Clusters::Coverage::PrepareBlock.call(
              height: height
            )

          return prepared unless prepared[:prepared]
          return prepared if prepared[:already_completed]

          page =
            Clusters::Coverage::ProcessPage.call(
              height: prepared.fetch(:height),
              batch_size: batch_size
            )

          {
            ok: page[:ok],
            prepared: prepared,
            page: page,
            rescheduled: false
          }
        end
      end

      private

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
          enabled_env: ENABLED_ENV,
          rescheduled: false
        }
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
              ex: LOCK_TTL_SECONDS
            )
          end

        return locked_result unless acquired

        yield
      ensure
        if acquired
          Sidekiq.redis do |redis|
            redis.del(LOCK_KEY) if redis.get(LOCK_KEY) == token
          end
        end
      end

      def locked_result
        {
          ok: true,
          status: "locked",
          rescheduled: false
        }
      end

      def pipeline_denied_result(decision)
        Rails.logger.info(
          "[cluster_coverage_incremental] " \
          "skipped reason=pipeline_controller_denied " \
          "decision=#{decision.inspect}"
        )

        {
          ok: true,
          status: "skipped",
          reason: "pipeline_controller_denied",
          decision: decision,
          rescheduled: false
        }
      end
    end
  end
end
