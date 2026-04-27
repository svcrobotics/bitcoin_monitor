# frozen_string_literal: true

class ClusterScanJob < ApplicationJob
  queue_as :p3_clusters

  LOCK_KEY = "lock:cluster_scan"
  LOCK_TTL = 30.minutes.to_i

  def perform
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

    locked = redis.set(
      LOCK_KEY,
      "#{Process.pid}:#{Time.current.to_i}",
      nx: true,
      ex: LOCK_TTL
    )

    unless locked
      Rails.logger.info("[cluster_scan] skip already_running redis_lock=#{LOCK_KEY}")
      return
    end

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
  ensure
    redis&.del(LOCK_KEY)
  end
end