# frozen_string_literal: true

require "sidekiq"
require "sidekiq/cron/job"

Sidekiq.configure_server do |config|
  config.on(:startup) do
    next unless ENV["LAYER1_STRICT_SCHEDULER"] == "1"

    schedule = {
      "layer1_strict_tip_sync_kick" => {
        "cron" => ENV.fetch(
          "LAYER1_STRICT_CRON",
          "*/1 * * * *"
        ),
        "class" => "Layer1::StrictTipSyncKickJob",
        "queue" => "scheduler",
        "description" =>
          "Checks and starts Layer1 strict independently every minute"
      },
      "tx_outputs_spent_sync_kick" => {
        "cron" => ENV.fetch(
          "TX_OUTPUTS_SPENT_ASYNC_CRON",
          "*/1 * * * *"
        ),
        "class" => "Layer1::TxOutputsSpentSyncKickJob",
        "queue" => "scheduler",
        "description" =>
          "Synchronizes tx_outputs spent flags outside Layer1 strict"
      },
      "tx_output_projection_kick" => {
        "cron" => ENV.fetch(
          "TX_OUTPUT_PROJECTION_ASYNC_CRON",
          "*/1 * * * *"
        ),
        "class" => "Layer1::TxOutputProjectionKickJob",
        "queue" => "scheduler",
        "description" =>
          "Projects historical tx_outputs outside Layer1 strict"
      }
    }

    Sidekiq::Cron::Job.load_from_hash!(schedule)

    job = Sidekiq::Cron::Job.find("layer1_strict_tip_sync_kick")

    raise "Layer1 strict scheduler was not registered" unless job

    Rails.logger.info(
      "[layer1_strict_scheduler] loaded " \
      "status=#{job.status} cron=#{job.cron}"
    )
  rescue StandardError => error
    Rails.logger.error(
      "[layer1_strict_scheduler] startup_error " \
      "#{error.class}: #{error.message}\n" \
      "#{error.backtrace&.first(20)&.join("\n")}"
    )

    raise
  end
end
