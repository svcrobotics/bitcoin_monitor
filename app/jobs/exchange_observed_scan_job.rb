# frozen_string_literal: true

class ExchangeObservedScanJob < ApplicationJob
  queue_as :low

  def perform(days_back: nil, last_n_blocks: nil)
    meta = {
      days_back: days_back,
      last_n_blocks: last_n_blocks
    }

    JobRunner.run!("exchange_observed_scan", meta: meta, triggered_by: "cron") do |jr|
      JobRunner.heartbeat!(jr)

      res = ExchangeObservedScanner.call(
        days_back: days_back,
        last_n_blocks: last_n_blocks
      )

      JobRunner.heartbeat!(jr)

      jr.update!(
        meta: meta.merge(res).to_json
      )

      res
    end
  end
end