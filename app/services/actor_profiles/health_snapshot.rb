# frozen_string_literal: true

module ActorProfiles
  class HealthSnapshot
    QUEUES = %w[
      p3_actor_profile_light
      p3_actor_profile_heavy
      actor_labels
    ].freeze

    def self.call
      new.call
    end

    def call
      {
        module: "actor_profiles_health",
        source: "actor_profiles_health_snapshot",
        generated_at: Time.current,
        status: status,

        counts: {
          actor_profiles: ActorProfile.count,
          actor_labels: ActorLabel.count,
          clusters: Cluster.count,
          legacy_cluster_profiles_disabled: true,
          dirty_actor_profiles: dirty_actor_profiles
        },

        activity: {
          last_actor_profile_at: ActorProfile.maximum(:updated_at),
          last_actor_label_at: ActorLabel.maximum(:updated_at),
          last_cluster_at: Cluster.maximum(:updated_at),
          last_cluster_profile_at: nil,
          legacy_cluster_profiles_disabled: true
        },

        queues: sidekiq_queues,
        workers: workers
      }
    end

    private

    def status
      last_profile = ActorProfile.maximum(:updated_at)
      queues = sidekiq_queues

      return "critical" if last_profile.blank?
      return "critical" if last_profile < 12.hours.ago
      return "warning" if last_profile < 6.hours.ago
      return "warning" if dirty_actor_profiles.positive?
      return "warning" if queues.values.any? { |v| v.to_i.positive? }

      "healthy"
    end

    def dirty_actor_profiles
      ActorProfiles::DirtyMarker.redis.scard(ActorProfiles::DirtyMarker::KEY).to_i
    rescue StandardError
      0
    end

    def sidekiq_queues
      require "sidekiq/api"

      QUEUES.to_h do |name|
        [name, Sidekiq::Queue.new(name).size]
      end
    rescue StandardError => e
      { error: e.message }
    end

    def workers
      require "sidekiq/api"

      Sidekiq::Workers.new.map do |_process_id, _thread_id, work|
        h = work.instance_variable_get(:@hsh)
        payload = JSON.parse(h["payload"]) rescue {}

        {
          queue: h["queue"],
          klass: payload["class"],
          args: payload["args"]
        }
      end.select do |w|
        QUEUES.include?(w[:queue])
      end
    rescue StandardError => e
      [{ error: e.message }]
    end
  end
end