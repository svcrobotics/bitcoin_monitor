# app/jobs/inflow_outflow_details_build_job.rb
class InflowOutflowDetailsBuildJob < ApplicationJob
  queue_as :low

  def perform(day: nil, days_back: nil)
    meta = {
      day: day,
      days_back: days_back
    }

    JobRunner.run!("inflow_outflow_details_build", meta: meta, triggered_by: "cron") do |jr|
      JobRunner.heartbeat!(jr)

      res = InflowOutflowDetailsBuilder.call(
        day: day,
        days_back: days_back
      )

      JobRunner.heartbeat!(jr)

      jr.update!(
        meta: meta.merge(result: res).to_json
      )

      res
    end
  end
end