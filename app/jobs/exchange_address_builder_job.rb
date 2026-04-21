# app/jobs/exchange_address_builder_job.rb
class ExchangeAddressBuilderJob < ApplicationJob
  queue_as :low

  def perform(blocks_back: nil, days_back: nil, reset: false)
    meta = {
      blocks_back: blocks_back,
      days_back: days_back,
      reset: reset
    }

    JobRunner.run!("exchange_address_builder", meta: meta, triggered_by: "cron") do |jr|
      JobRunner.heartbeat!(jr)

      res = ExchangeAddressBuilder.call(
        blocks_back: blocks_back,
        days_back: days_back,
        reset: reset
      )

      JobRunner.heartbeat!(jr)

      jr.update!(
        meta: meta.merge(result: res).to_json
      )

      res
    end
  end
end