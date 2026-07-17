# frozen_string_literal: true

module Layer1
  class TxOutputProjectionKickJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduler, retry: false

    def perform
      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "tx_output_projection_kick"
        )

      Rails.logger.info(
        "[tx_output_projection_kick_job] " \
        "wakeup=#{result.inspect}"
      )

      result.merge(
        ok: true,
        status:
          result[:enqueued] ? "wakeup_enqueued" : "wakeup_duplicate"
      )
    end
  end
end
