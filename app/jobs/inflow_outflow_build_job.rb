# frozen_string_literal: true

class InflowOutflowBuildJob < ApplicationJob
  queue_as :p2_flows

  def perform(days_back: 2)
    JobRunner.run!(
      "inflow_outflow_build",
      triggered_by: "cron",
      meta: { days_back: days_back }
    ) do
      InflowOutflowPipelineBuilder.call(days_back: days_back)
    end
  end
end