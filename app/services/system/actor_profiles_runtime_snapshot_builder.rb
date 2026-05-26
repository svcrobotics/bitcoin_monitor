# frozen_string_literal: true

module System
  class ActorProfilesRuntimeSnapshotBuilder
    def self.call
      new.call
    end

    def call
      {
        profiles_count: actor_profile_count,
        deltas_total: delta_count,
        deltas_unprocessed: unprocessed_delta_count,
        dirty_clusters: dirty_clusters_count,
        queues: queues,
        recent_profiles: recent_profiles,
        recent_deltas_15m: recent_deltas_15m,
        processed_deltas_15m: processed_deltas_15m,
        status: status
      }
    end

    private

    def actor_profile_count
      defined?(ActorProfile) ? ActorProfile.count : 0
    end

    def delta_count
      defined?(ActorProfileDelta) ? ActorProfileDelta.count : 0
    end

    def unprocessed_delta_count
      defined?(ActorProfileDelta) ? ActorProfileDelta.unprocessed.count : 0
    end

    def dirty_clusters_count
      ActorProfiles::DirtyMarker.redis.scard(ActorProfiles::DirtyMarker::KEY)
    rescue
      0
    end

    def queues
      require "sidekiq/api"

      {
        light: Sidekiq::Queue.new("p3_actor_profile_light").size,
        heavy: Sidekiq::Queue.new("p3_actor_profile_heavy").size
      }
    rescue
      { light: 0, heavy: 0 }
    end

    def recent_profiles
      return [] unless defined?(ActorProfile)

      ActorProfile
        .order(updated_at: :desc)
        .limit(5)
        .pluck(:id, :cluster_id, :classification, :priority, :last_computed_height, :updated_at)
        .map do |id, cluster_id, classification, priority, height, updated_at|
          {
            id: id,
            cluster_id: cluster_id,
            classification: classification,
            priority: priority,
            last_computed_height: height,
            updated_at: updated_at
          }
        end
    end

    def recent_deltas_15m
      return 0 unless defined?(ActorProfileDelta)

      ActorProfileDelta.where("created_at >= ?", 15.minutes.ago).count
    end

    def processed_deltas_15m
      return 0 unless defined?(ActorProfileDelta)

      ActorProfileDelta.where("processed_at >= ?", 15.minutes.ago).count
    end

    def status
      return "warning" if unprocessed_delta_count > 10_000
      return "warning" if dirty_clusters_count > 2_000
      return "running" if queues[:light].to_i.positive? || queues[:heavy].to_i.positive?
      return "running" if unprocessed_delta_count.positive?

      "ok"
    end
  end
end
