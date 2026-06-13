# app/jobs/actor_labels_refresh_job.rb
# frozen_string_literal: true

class ActorLabelsRefreshJob < ApplicationJob
  queue_as :actor_labels

  LOCK_KEY = "actor_labels_refresh_lock"
  LOCK_TTL = 30.minutes

  def perform
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
          source: "exchange_metrics+internal_etf_candidates"
        }
      ) do |jr|
        JobRunner.progress!(jr, pct: 10, label: "starting")

        exchange_metric_result = Actors::RefreshExchangeLabelsFromMetrics.call

        result = {
          exchange_like_from_metrics: exchange_metric_result
        }

        JobRunner.progress!(jr, pct: 100, label: "done", meta: result)

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