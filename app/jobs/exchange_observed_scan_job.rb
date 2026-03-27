# frozen_string_literal: true

class ExchangeObservedScanJob < ApplicationJob
  queue_as :low

  def perform(days_back: nil, last_n_blocks: nil)
    meta = {
      days_back: days_back,
      last_n_blocks: last_n_blocks
    }.to_json

    JobRun.log!("exchange_observed_scan", meta: meta) do |jr|
      res = ExchangeObservedScanner.call(
        days_back: days_back,
        last_n_blocks: last_n_blocks
      )

      if jr
        jr.update!(
          meta: {
            days_back: days_back,
            last_n_blocks: last_n_blocks
          }.merge(res).to_json
        )
      end

      res
    end
  end
end