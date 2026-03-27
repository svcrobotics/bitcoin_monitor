# app/jobs/inflow_outflow_details_build_job.rb
class InflowOutflowDetailsBuildJob < ApplicationJob
  queue_as :low

  def perform(day: nil, days_back: nil)
    meta = {
      day: day,
      days_back: days_back
    }.to_json

    JobRun.log!("inflow_outflow_details_build", meta: meta) do
      InflowOutflowDetailsBuilder.call(
        day: day,
        days_back: days_back
      )
    end
  end
end