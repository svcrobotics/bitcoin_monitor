# app/jobs/inflow_outflow_capital_behavior_build_job.rb
class InflowOutflowCapitalBehaviorBuildJob < ApplicationJob
  queue_as :low

  def perform(day: nil, days_back: nil)
    meta = {
      day: day,
      days_back: days_back
    }.to_json

    JobRun.log!("inflow_outflow_capital_behavior_build", meta: meta) do
      InflowOutflowCapitalBehaviorBuilder.call(
        day: day,
        days_back: days_back
      )
    end
  end
end