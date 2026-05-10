# frozen_string_literal: true

class WhaleScanJob < ApplicationJob
  queue_as :p4_analytics

  DEFAULT_BLOCKS = Integer(ENV.fetch("WHALE_SCAN_BLOCKS", "144")) rescue 144

  def perform(last_n_blocks: DEFAULT_BLOCKS)
    JobRunner.run!(
      "whale_scan",
      triggered_by: ENV.fetch("TRIGGERED_BY", "cron"),
      meta: {
        last_n_blocks: last_n_blocks,
        source: "layer1"
      }
    ) do |jr|
      WhaleLayer1Scanner.call(
        last_n_blocks: last_n_blocks,
        job_run: jr
      )
    end
  end
end