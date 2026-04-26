# frozen_string_literal: true

class ClusterScanJob < ApplicationJob
  queue_as :p3_clusters

  def perform
    JobRunner.run!(
      "cluster_scan",
      triggered_by: ENV.fetch("TRIGGERED_BY", "sidekiq_cron"),
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      limit = Integer(ENV.fetch("CLUSTER_SCAN_LIMIT", "50"))

      result = Clusters::ScanAndDispatch.call(
        limit: limit,
        job_run: jr
      )

      JobRunner.heartbeat!(jr)

      result
    end
  end
end