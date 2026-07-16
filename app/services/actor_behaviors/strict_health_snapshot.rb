# frozen_string_literal: true

require "sidekiq/api"

module ActorBehaviors
  class StrictHealthSnapshot
    STALE_AFTER = BuildDispatcher::STALE_AFTER

    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      profiles = ActorProfiles::CertifiedScope.call
      eligible = profiles.count
      certified_scope = ActorBehaviorSnapshot.where(
        status: "certified", certification_scope: "strict"
      )
      certified = certified_scope.count
      stale = stale_scope(profiles).count
      handoffs = handoff_metrics
      sidekiq = sidekiq_metrics

      {
        status: sidekiq[:available] ? "available" : "unavailable",
        actor_profiles_eligible: eligible,
        actor_behaviors_certified: certified,
        actor_behaviors_missing: [eligible - certified + stale, 0].max,
        actor_behaviors_stale: stale,
        coverage: eligible.zero? ? nil : certified.fdiv(eligible),
        latest_source_height: certified_scope.maximum(:profile_height),
        latest_certified_at: certified_scope.maximum(:certified_at),
        handoffs: handoffs,
        sidekiq: sidekiq,
        automation_missing: automation_missing?(handoffs, sidekiq),
        generated_at: @now
      }
    rescue ActiveRecord::ActiveRecordError
      unavailable
    end

    private

    def stale_scope(profiles)
      ActorBehaviorSnapshot.joins(:actor_profile).merge(profiles).where(
        "actor_behavior_snapshots.cluster_composition_version <> " \
        "actor_profiles.cluster_composition_version OR " \
        "actor_behavior_snapshots.profile_height <> actor_profiles.last_computed_height OR " \
        "actor_behavior_snapshots.source_hash <> " \
        "actor_profiles.metadata->>'address_spend_projection_hash'"
      )
    end

    def handoff_metrics
      counts = ActorBehaviorBuildHandoff.group(:status).count
      oldest = ActorBehaviorBuildHandoff.where(status: %w[pending failed processing])
        .minimum(:created_at)
      {
        pending: counts.fetch("pending", 0),
        processing: counts.fetch("processing", 0),
        failed: counts.fetch("failed", 0),
        stale: ActorBehaviorBuildHandoff.where(status: "processing")
          .where("claimed_at < ?", @now - STALE_AFTER).count,
        oldest_age_seconds: oldest ? [(@now - oldest).to_f, 0.0].max : nil
      }
    end

    def sidekiq_metrics
      queue = Sidekiq::Queue.new("actor_behavior_strict")
      workers = Sidekiq::WorkSet.new.count do |_process_id, _thread_id, work|
        payload = work.respond_to?(:payload) ? work.payload : work.to_h["payload"]
        payload.is_a?(Hash) && payload["queue"] == "actor_behavior_strict"
      end
      scheduled = Sidekiq::ScheduledSet.new.count do |job|
        job.respond_to?(:queue) && job.queue == "actor_behavior_strict"
      end
      {
        available: true,
        queue_size: queue.size,
        queue_latency_seconds: finite_nonnegative(queue.latency),
        worker_count: workers,
        scheduled_count: scheduled
      }
    rescue StandardError
      {
        available: false, queue_size: nil, queue_latency_seconds: nil,
        worker_count: nil, scheduled_count: nil
      }
    end

    def finite_nonnegative(value)
      numeric = Float(value)
      numeric.finite? && numeric >= 0 ? numeric : nil
    rescue ArgumentError, TypeError
      nil
    end

    def automation_missing?(handoffs, sidekiq)
      return false unless sidekiq[:available]

      backlog = handoffs.values_at(:pending, :failed, :stale).sum.positive?
      inactive = sidekiq.values_at(:queue_size, :worker_count, :scheduled_count).sum.zero?
      backlog && inactive
    end

    def unavailable
      {
        status: "unavailable",
        actor_profiles_eligible: nil,
        actor_behaviors_certified: nil,
        actor_behaviors_missing: nil,
        actor_behaviors_stale: nil,
        coverage: nil,
        latest_source_height: nil,
        latest_certified_at: nil,
        handoffs: nil,
        sidekiq: {
          available: false, queue_size: nil, queue_latency_seconds: nil,
          worker_count: nil, scheduled_count: nil
        },
        automation_missing: false,
        generated_at: @now
      }
    end
  end
end
