# app/jobs/actor_profiles_dispatcher_job.rb
# frozen_string_literal: true

class ActorProfilesDispatcherJob < ApplicationJob
  queue_as :p3_actor_profile_light

  BATCH_SIZE = ENV.fetch("ACTOR_PROFILE_DISPATCH_BATCH_SIZE", 500).to_i
  KEY = ActorProfiles::DirtyMarker::KEY

  def perform(batch_size: BATCH_SIZE)
    unless ENV["ACTOR_PROFILE_REDIS_RECOVERY_ENABLED"] == "1"
      return { ok: true, status: "skipped", reason: "legacy_recovery_disabled" }
    end

    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

    cluster_ids = redis.srandmember(KEY, batch_size)
    cluster_ids = Array(cluster_ids).map(&:to_i).uniq.select(&:positive?)

    return { ok: true, imported: 0, remaining: redis.scard(KEY) } if cluster_ids.empty?

    admission = ActorProfiles::Admission.register_latest(
      cluster_ids: cluster_ids,
      reason: "recovery"
    )
    registered = admission.fetch(:registered_cluster_ids)
    redis.srem(KEY, registered) if registered.any?

    {
      ok: true,
      status: "imported",
      imported: registered.size,
      remaining: redis.scard(KEY)
    }
  end
end
