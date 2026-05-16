# frozen_string_literal: true

class ActorLabelsRefreshJob < ApplicationJob
  queue_as :p3_clusters_refresh

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
      result = ActorLabels::RefreshFromClusterProfile.call(limit: limit)

      Rails.logger.info(
        "[actor_labels_refresh] done " \
        "created=#{result[:created]} " \
        "updated=#{result[:updated]} " \
        "skipped=#{result[:skipped]}"
      )

      result
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