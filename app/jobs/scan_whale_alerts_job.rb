# app/jobs/scan_whale_alerts_job.rb
class ScanWhaleAlertsJob < ApplicationJob
  queue_as :default

  def perform(last_n_blocks: 144)
    WhaleAlertScanner.new.scan_last_n_blocks!(last_n_blocks)
  end
end
