# frozen_string_literal: true

module Layer1
  class StrictTipSyncKickJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduler, retry: false

    def perform
      result =
        StrictPipeline::SchedulerJob
          .new
          .perform

      Rails.logger.info(
        "[layer1_strict_tip_sync_kick_job] " \
        "scheduler=#{result.inspect}"
      )

      {
        ok: true,
        status: "scheduler_checked",
        scheduler: result
      }
    end
  end
end
