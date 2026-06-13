# frozen_string_literal: true

module ActorLabels
  class HealthSnapshot
    QUEUES = %w[
      actor_labels
    ].freeze

    def self.call
      new.call
    end

    def call
      {
        module: "actor_labels_health",
        source: "actor_labels_health_snapshot",
        generated_at: Time.current,
        status: status,

        counts: {
          actor_labels: ActorLabel.count,
          exchange_like: ActorLabel.where(label: "exchange_like").count,
          whale_like: ActorLabel.where(label: "whale_like").count,
          etf_candidate: ActorLabel.where(label: "etf_candidate").count,
          service_like: ActorLabel.where(label: "service_like").count,
          retail_like: ActorLabel.where(label: "retail_like").count,
          unknown: ActorLabel.where(label: "unknown").count
        },

        activity: {
          last_actor_label_at: ActorLabel.maximum(:updated_at),
          last_actor_profile_at: ActorProfile.maximum(:updated_at),
          by_label: ActorLabel.group(:label).maximum(:updated_at)
        },

        queues: sidekiq_queues,
        workers: workers
      }
    end

    private

    def status
      last_label = ActorLabel.maximum(:updated_at)

      return "critical" if last_label.blank?
      return "warning" if last_label < 6.hours.ago

      "healthy"
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
