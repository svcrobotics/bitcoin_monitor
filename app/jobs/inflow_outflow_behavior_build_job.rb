# app/jobs/inflow_outflow_behavior_build_job.rb
class InflowOutflowBehaviorBuildJob < ApplicationJob
  queue_as :low

  def perform(day: nil, days_back: nil)
    meta = {
      day: day,
      days_back: days_back
    }.to_json

    JobRun.log!("inflow_outflow_behavior_build", meta: meta) do
      InflowOutflowBehaviorBuilder.call(
        day: day,
        days_back: days_back
      )
    end
  end
end