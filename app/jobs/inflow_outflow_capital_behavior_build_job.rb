# frozen_string_literal: true

class InflowOutflowCapitalBehaviorBuildJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "inflow_outflow_capital_behavior_build",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = InflowOutflowCapitalBehaviorBuilder.call

      JobRunner.heartbeat!(jr)

      result
    end
  end
end