# frozen_string_literal: true

class TrueFlowRebuildJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "true_flow_rebuild",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = TrueExchangeFlowRebuilder.call(
        days_back: Integer(ENV.fetch("TRUE_FLOW_DAYS_BACK", "7")),
        only_missing: false
      )

      JobRunner.heartbeat!(jr)

      result
    end
  end
end
