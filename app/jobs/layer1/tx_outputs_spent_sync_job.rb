# frozen_string_literal: true

require "securerandom"

module Layer1
  class TxOutputsSpentSyncJob
    include Sidekiq::Job

    sidekiq_options queue: :tx_outputs_async, retry: 5

    LOCK_KEY = "layer1:tx_outputs_spent_sync:lock"
    LOCK_TTL_SECONDS = 300

    def perform
      return disabled_result unless TxOutputsSpentSync::Config.enabled?

      decision =
        pipeline_decision

      unless decision[:allowed]
        Rails.logger.info(
          "[tx_outputs_async] deferred reason=pipeline_controller_denied decision=#{decision.inspect}"
        )

        return {
          ok: true,
          status: "deferred",
          reason: "pipeline_controller_denied",
          decision: decision
        }
      end

      with_lock do
        gate = TxOutputsSpentSync::Gate.call

        unless gate[:ready]
          Rails.logger.info(
            "[tx_outputs_spent_sync_job] deferred gate=#{gate.inspect}"
          )

          next({ ok: true, status: "deferred", gate: gate })
        end

        record = TxOutputsSpentSync::NextRecord.call
        next({ ok: true, status: "idle" }) unless record

        result = TxOutputsSpentSync::SyncHeight.call(sync_record: record)

        post_batch_decision =
          pipeline_decision

        unless post_batch_decision[:allowed]
          Rails.logger.info(
            "[tx_outputs_spent_sync_job] yielded_to_layer1 " \
            "height=#{record.height} decision=#{post_batch_decision.inspect}"
          )

          next(
            {
              ok: true,
              status: "yielded_to_layer1",
              reason: "pipeline_controller_denied",
              decision: post_batch_decision,
              sync_result: result
            }
          )
        end

        self.class.perform_in(1) if TxOutputsSpentSync::WorkAvailable.call

        result
      end
    end

    private

    def disabled_result
      { ok: true, status: "disabled" }
    end

    def pipeline_decision
      System::PipelineController.decision(:tx_outputs_async)
    rescue NoMethodError
      System::PipelineController.layer1_heavy_decision(:tx_outputs_async)
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
