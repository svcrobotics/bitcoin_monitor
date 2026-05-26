# app/jobs/actor_profiles_dispatcher_job.rb
# frozen_string_literal: true

class ActorProfilesDispatcherJob < ApplicationJob
  queue_as :p3_actor_profile_light

  BATCH_SIZE = ENV.fetch("ACTOR_PROFILE_DISPATCH_BATCH_SIZE", 500).to_i
  KEY = ActorProfiles::DirtyMarker::KEY

  def perform(batch_size: BATCH_SIZE)
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

    cluster_ids = redis.spop(KEY, batch_size)
    cluster_ids = Array(cluster_ids).map(&:to_i).uniq.select(&:positive?)

    return { enqueued: 0 } if cluster_ids.empty?

    cluster_ids.each do |cluster_id|
      queue = heavy_cluster?(cluster_id) ? :p3_actor_profile_heavy : :p3_actor_profile_light

      ActorProfilesComputeJob
        .set(queue: queue)
        .perform_later(cluster_id)
    end

    {
      enqueued: cluster_ids.size,
      remaining: redis.scard(KEY)
    }
  end

  private

  def heavy_cluster?(cluster_id)
    address_count = Address.where(cluster_id: cluster_id).limit(20_001).count

    address_count > ENV.fetch("ACTOR_PROFILE_HEAVY_ADDRESS_COUNT", 20_000).to_i
  rescue => e
    Rails.logger.warn("[actor_profiles_dispatcher] heavy_cluster_check_failed cluster_id=#{cluster_id} error=#{e.class}: #{e.message}")
    false
  end
end