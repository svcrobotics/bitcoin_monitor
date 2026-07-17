# frozen_string_literal: true

module Layer1
  class TxOutputsSpentSyncKickJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduler, retry: false

    def perform
      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "tx_outputs_spent_sync_kick"
        )

      Rails.logger.info(
        "[tx_outputs_spent_sync_kick_job] " \
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
