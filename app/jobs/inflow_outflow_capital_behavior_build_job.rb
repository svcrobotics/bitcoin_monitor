# frozen_string_literal: true

class InflowOutflowCapitalBehaviorBuildJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "inflow_outflow_capital_behavior_build",
      triggered_by: ENV.fetch("TRIGGERED_BY", "sidekiq_cron"),
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      days_back = Integer(ENV.fetch("DAYS_BACK", ENV.fetch("DAYS", "2")))

      result = InflowOutflowCapitalBehaviorBuilder.call(days_back: days_back)

      JobRunner.heartbeat!(jr)

      result
    end
  end
end