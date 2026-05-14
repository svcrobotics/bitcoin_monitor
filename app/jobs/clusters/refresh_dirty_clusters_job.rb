# frozen_string_literal: true

module Clusters
  class RefreshDirtyClustersJob < ApplicationJob
    queue_as :p3_clusters_refresh

    JOB_NAME = "cluster_refresh_dirty_clusters"

    LOCK_KEY = "lock:cluster_refresh_dirty_clusters"
    LOCK_TTL = 10.minutes.to_i

    def perform(cluster_ids = nil)
      redis = Redis.new(
        url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
      )

      locked = redis.set(
        LOCK_KEY,
        "#{Process.pid}:#{Time.current.to_i}",
        nx: true,
        ex: LOCK_TTL
      )

      unless locked
        Rails.logger.info(
          "[cluster_refresh] skip already_running redis_lock=#{LOCK_KEY}"
        )

        return {
          ok: true,
          skipped: true,
          reason: "lock_active"
        }
      end

      JobRunner.run!(
        JOB_NAME,
        meta: {
          requested_cluster_ids: Array(cluster_ids).compact.size,
          dirty_queue_size_before: Clusters::DirtyClusterQueue.size
        },
        triggered_by: ENV.fetch("TRIGGERED_BY", "sidekiq_cron")
      ) do |job_run|
        perform_refresh(cluster_ids, job_run: job_run)
      end
    ensure
      redis&.del(LOCK_KEY)
    end

    private

    def perform_refresh(cluster_ids = nil, job_run: nil)
      layer1_lag = Blockchain::State::Layer1Lag.call

      max_allowed_lag =
        Integer(
          ENV.fetch(
            "CLUSTER_REFRESH_SKIP_IF_LAYER1_LAG_GT",
            "5"
          )
        )

      if layer1_lag > max_allowed_lag
        Rails.logger.info(
          "[cluster_refresh] skip layer1_lag=#{layer1_lag}"
        )

        return {
          ok: true,
          skipped: true,
          reason: "layer1_lag",
          layer1_lag: layer1_lag
        }
      end

      dirty_before = Clusters::DirtyClusterQueue.size

      dynamic_batch_size =
        if dirty_before >= 50_000
          1000
        elsif dirty_before >= 20_000
          500
        elsif dirty_before >= 5_000
          250
        else
          Integer(
            ENV.fetch("CLUSTER_REFRESH_BATCH_SIZE", "100")
          )
        end

      cluster_ids =
        if cluster_ids.present?
          Array(cluster_ids)
            .map(&:to_i)
            .uniq
        else
          Clusters::DirtyClusterQueue.pop(
            limit: dynamic_batch_size
          )
        end

      if cluster_ids.empty?
        return {
          ok: true,
          skipped: true,
          reason: "no_dirty_clusters",
          dirty_queue_size_before: dirty_before,
          dirty_queue_size_after: Clusters::DirtyClusterQueue.size
        }
      end

      Rails.logger.info(
        "[cluster_refresh] refreshing count=#{cluster_ids.size} " \
        "dirty_before=#{dirty_before}"
      )

      JobRunner.progress!(
        job_run,
        pct: 5,
        label: "refreshing #{cluster_ids.size} dirty clusters",
        meta: {
          layer1_lag: layer1_lag,
          dirty_queue_size_before: dirty_before,
          batch_size: cluster_ids.size
        }
      )

      refreshed =
        Clusters::DirtyClusterRefresher.call(
          cluster_ids: cluster_ids
        )

      dirty_after = Clusters::DirtyClusterQueue.size

      removed = dirty_before - dirty_after

      JobRunner.progress!(
        job_run,
        pct: 100,
        label: "refreshed #{refreshed} clusters",
        meta: {
          refreshed: refreshed,
          batch_size: cluster_ids.size,
          layer1_lag: layer1_lag,
          removed_from_queue: removed,
          dirty_queue_size_before: dirty_before,
          dirty_queue_size_after: dirty_after
        }
      )

      {
        ok: true,
        refreshed: refreshed,
        batch_size: cluster_ids.size,
        layer1_lag: layer1_lag,
        dirty_queue_size_before: dirty_before,
        dirty_queue_size_after: dirty_after,
        removed_from_queue: removed
      }
    end
  end
end