# frozen_string_literal: true

class InflowOutflowBuildJob < ApplicationJob
  queue_as :p2_flows

  def perform
    JobRunner.run!(
      "inflow_outflow_build",
      triggered_by: ENV.fetch("TRIGGERED_BY", "sidekiq_cron"),
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      days_back = Integer(ENV.fetch("DAYS_BACK", ENV.fetch("DAYS", "2")))

      result = InflowOutflowBuilder.call(days_back: days_back)
      InflowOutflowDetailsBuildJob.perform_later
      
      JobRunner.heartbeat!(jr)

      result
    end
  end
end