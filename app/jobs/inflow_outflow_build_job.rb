# app/jobs/inflow_outflow_build_job.rb
class InflowOutflowBuildJob < ApplicationJob
  queue_as :low

  def perform(day: nil, days_back: nil)
    meta = {
      day: day,
      days_back: days_back
    }

    JobRunner.run!("inflow_outflow_build", meta: meta, triggered_by: "cron") do |jr|
      JobRunner.heartbeat!(jr)

      res = InflowOutflowBuilder.call(
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