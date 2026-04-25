# frozen_string_literal: true

class WhaleScanJob < ApplicationJob
  queue_as :default

  DEFAULT_BLOCKS = Integer(ENV.fetch("WHALE_SCAN_BLOCKS", "72"))

  def perform
    JobRunner.run!(
      "whale_scan",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      ScanWhaleAlertsJob.perform_now(last_n_blocks: DEFAULT_BLOCKS)

      JobRunner.heartbeat!(jr)

      { last_n_blocks: DEFAULT_BLOCKS }
    end
  end
end
