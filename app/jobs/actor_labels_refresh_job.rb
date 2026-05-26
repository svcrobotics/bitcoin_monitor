# app/jobs/actor_labels_refresh_job.rb
# frozen_string_literal: true

class ActorLabelsRefreshJob < ApplicationJob
  queue_as :actor_labels

  DEFAULT_LIMIT = 10_000
  LOCK_KEY = "actor_labels_refresh_lock"
  LOCK_TTL = 30.minutes

  def perform(limit: DEFAULT_LIMIT)
    lock = System::RedisJobLock.new(
      key: LOCK_KEY,
      ttl: LOCK_TTL
    )

    return skipped_locked unless lock.acquire

    begin
      JobRunner.run!(
        "actor_labels_refresh",
        triggered_by: "sidekiq_cron",
        meta: {
          limit: limit,
          source: "cluster_profiles"
        }
      ) do |jr|
        JobRunner.progress!(
          jr,
          pct: 5,
          label: "starting",
          meta: { limit: limit }
        )

        cluster_profile_result = ActorLabels::RefreshFromClusterProfile.call(
          limit: limit,
          job_run: jr
        )

        result = {
          cluster_profiles: cluster_profile_result
        }

        JobRunner.progress!(
          jr,
          pct: 100,
          label: "done",
          meta: result.merge(limit: limit)
        )

        result
      end
    ensure
      lock.release
    end
  end

  private

  def skipped_locked
    Rails.logger.info("[actor_labels_refresh] skipped reason=locked")

    {
      ok: true,
      skipped: true,
      reason: "locked"
    }
  end
end