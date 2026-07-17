# frozen_string_literal: true

require "securerandom"

module Layer1
  class TxOutputProjectionJob
    include Sidekiq::Job

    sidekiq_options queue: :tx_output_projection, retry: 5

    LOCK_KEY = "layer1:tx_output_projection:lock"
    LOCK_TTL_SECONDS = 600

    def perform
      return disabled_result unless TxOutputProjection::Config.enabled?

      decision =
        System::PipelineController.layer1_heavy_decision(:tx_output_projection)

      unless decision[:allowed]
        Rails.logger.info(
          "[tx_output_projection_job] deferred " \
          "reason=pipeline_controller_denied decision=#{decision.inspect}"
        )

        return {
          ok: true,
          status: "deferred",
          reason: "pipeline_controller_denied",
          decision: decision
        }
      end

      with_lock do
        record = TxOutputProjection::NextRecord.call
        next({ ok: true, status: "idle" }) unless record

        result =
          TxOutputProjection::ProjectHeight.call(
            projection_block: record
          )

        self.class.perform_in(1) if TxOutputProjection::NextRecord.call

        result
      end
    end

    private

    def disabled_result
      { ok: true, status: "disabled" }
    end

    def with_lock
      redis = Redis.new(
        url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
      )
      token = SecureRandom.hex(16)
      acquired = redis.set(LOCK_KEY, token, nx: true, ex: LOCK_TTL_SECONDS)

      return { ok: true, status: "locked" } unless acquired

      yield
    ensure
      if acquired
        current = redis.get(LOCK_KEY)
        redis.del(LOCK_KEY) if current == token
      end
    end
  end
end
