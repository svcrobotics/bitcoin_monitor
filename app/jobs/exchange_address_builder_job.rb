# frozen_string_literal: true

class ExchangeAddressBuilderJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "exchange_address_builder",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = ExchangeAddressBuilder.call

      JobRunner.heartbeat!(jr)

      result
    end
  end
end