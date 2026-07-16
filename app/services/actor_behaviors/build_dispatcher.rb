# frozen_string_literal: true

module ActorBehaviors
  class BuildDispatcher
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 100
    MAX_ATTEMPTS = 5
    STALE_AFTER = 15.minutes

    class UnexpectedResult < StandardError; end

    def self.call(limit: DEFAULT_LIMIT, now: Time.current)
      new(limit:, now:).call
    end

    def self.claimable_scope(now: Time.current)
      retryable = ActorBehaviorBuildHandoff.where(status: %w[pending failed])
        .where("attempts < ?", MAX_ATTEMPTS)
      stale = ActorBehaviorBuildHandoff.where(status: "processing")
        .where("attempts < ?", MAX_ATTEMPTS)
        .where("claimed_at < ?", now - STALE_AFTER)
      retryable.or(stale)
    end

    def self.work_available?(now: Time.current)
      claimable_scope(now: now).exists?
    end

    def initialize(limit:, now:, logger: Rails.logger)
      @limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      @now = now
      @logger = logger
    end

    def call
      handoffs = claim
      results = handoffs.map { |handoff| process(handoff) }
      {
        ok: results.none? { |result| result[:status] == "failed" },
        claimed: handoffs.size,
        completed: results.count { |result| result[:status] == "completed" },
        failed: results.count { |result| result[:status] == "failed" },
        results: results
      }
    end

    private

    def claim
      claimed = []
      ApplicationRecord.transaction(requires_new: true) do
        self.class.claimable_scope(now: @now)
          .order(:source_height, :cluster_id, :id)
          .limit(@limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .each do |handoff|
            handoff.claim!(at: @now)
            claimed << handoff
          end
      end
      claimed
    end

    def process(handoff)
      result = StrictBuildFromProfile.call(
        cluster_id: handoff.cluster_id,
        cluster_composition_version: handoff.cluster_composition_version,
        profile_version: handoff.profile_version,
        source_height: handoff.source_height,
        source_hash: handoff.source_hash
      )
      case result.fetch(:status)
      when "built", "already_current", "superseded"
        handoff.complete!(at: Time.current)
        terminal_result(handoff, "completed", result)
      when "refused"
        handoff.fail!(error_class: "ActorBehaviorSourceRefused")
        terminal_result(handoff, "failed", result)
      else
        raise UnexpectedResult, "ActorBehavior returned a non-terminal result"
      end
    rescue StandardError => original
      persist_failure(handoff, original)
      raise original
    end

    def terminal_result(handoff, status, builder_result)
      {
        handoff_id: handoff.id,
        cluster_id: handoff.cluster_id,
        status: status,
        actor_behavior_status: builder_result.fetch(:status),
        reason: builder_result[:reason]
      }
    end

    def persist_failure(handoff, original)
      return unless handoff&.persisted? && handoff.status == "processing"

      handoff.fail!(error_class: original.class.name)
    rescue StandardError => secondary
      @logger.error(
        "[actor_behavior_build_dispatch] failure_persistence_failed " \
        "handoff_id=#{handoff.id} error_class=#{secondary.class.name}"
      )
    end
  end
end
