# app/jobs/exchange_address_builder_job.rb
class ExchangeAddressBuilderJob < ApplicationJob
  queue_as :low

  def perform(blocks_back: nil, days_back: nil, reset: false)
    meta = {
      blocks_back: blocks_back,
      days_back: days_back,
      reset: reset
    }.to_json

    JobRun.log!("exchange_address_builder", meta: meta) do
      ExchangeAddressBuilder.call(
        blocks_back: blocks_back,
        days_back: days_back,
        reset: reset
      )
    end
  end
end