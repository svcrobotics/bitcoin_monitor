# frozen_string_literal: true

class ClusterScanJob < ApplicationJob
  queue_as :p3_clusters

  LIMIT = Integer(ENV.fetch("CLUSTER_SCAN_LIMIT", "1"))

  def perform
    JobRunner.run!(
      "cluster_scan",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = Clusters::ScanAndDispatch.call(
        limit: LIMIT,
        job_run: jr
      )

      JobRunner.heartbeat!(jr)

      result
    end
  end
end
