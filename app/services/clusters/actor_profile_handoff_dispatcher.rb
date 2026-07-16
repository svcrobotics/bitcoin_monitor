# frozen_string_literal: true

module Clusters
  class ActorProfileHandoffDispatcher
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 100
    MAX_ATTEMPTS = 5
    STALE_AFTER = 15.minutes

    class InvalidCertification < StandardError; end
    class UnexpectedActorProfileResult < StandardError; end

    def self.call(limit: DEFAULT_LIMIT, now: Time.current)
      new(limit: limit, now: now).call
    end

    def self.work_available?(now: Time.current)
      claimable_scope(now: now).exists?
    end

    def self.claimable_scope(now:)
      retryable = ClusterActorProfileHandoff
        .joins(address_spend_dependency_join)
        .where(status: %w[pending failed])
        .where(
          "cluster_actor_profile_handoffs.attempts < ?",
          MAX_ATTEMPTS
        )
      stale = ClusterActorProfileHandoff
        .joins(address_spend_dependency_join)
        .where(status: "processing")
        .where(
          "cluster_actor_profile_handoffs.attempts < ?",
          MAX_ATTEMPTS
        )
        .where(
          "cluster_actor_profile_handoffs.claimed_at < ?",
          now - STALE_AFTER
        )
      retryable.or(stale)
    end

    def self.address_spend_dependency_join
      <<~SQL.squish
        INNER JOIN address_spend_projection_blocks
          ON address_spend_projection_blocks.height =
             cluster_actor_profile_handoffs.cluster_height
         AND address_spend_projection_blocks.block_hash =
             cluster_actor_profile_handoffs.block_hash
         AND address_spend_projection_blocks.status = 'completed'
      SQL
    end

    def initialize(limit:, now:, logger: Rails.logger)
      @limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      @now = now
      @logger = logger
    end

    def call
      handoffs = claim_handoffs
      results = handoffs.map { |handoff| process_handoff(handoff) }

      {
        ok: results.none? { |result| result[:status] == "failed" },
        claimed: handoffs.size,
        completed: results.count { |result| result[:status] == "completed" },
        failed: results.count { |result| result[:status] == "failed" },
        results: results
      }
    end

    private

    def claim_handoffs
      claimed = []
      ApplicationRecord.transaction(requires_new: true) do
        self.class.claimable_scope(now: @now)
          .order(:cluster_height, :cluster_id, :id)
          .limit(@limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .each do |handoff|
            handoff.claim!(at: @now)
            claimed << handoff
          end
      end
      claimed
    end

    def process_handoff(handoff)
      validate_certification!(handoff)
      actor_result = ActorProfiles::StrictBuildFromCluster.call(
        cluster_id: handoff.cluster_id,
        composition_version: handoff.composition_version,
        source_height: handoff.cluster_height,
        source_hash: handoff.block_hash
      )

      case actor_result.fetch(:status)
      when "built", "already_current", "superseded"
        handoff.complete!(at: Time.current)
        completed_result(handoff, actor_result)
      when "refused"
        handoff.fail!(error_class: "ActorProfileCompositionRefused")
        failed_result(handoff, actor_result)
      else
        raise UnexpectedActorProfileResult,
          "ActorProfile returned a non-terminal handoff result"
      end
    rescue StandardError => original_error
      persist_failure_without_masking(handoff, original_error)
      raise original_error
    end

    def validate_certification!(handoff)
      checkpoint = ClusterProcessedBlock.find_by(height: handoff.cluster_height)
      unless checkpoint&.status == "processed" && checkpoint.block_hash == handoff.block_hash
        raise InvalidCertification,
          "Cluster certification is missing or inconsistent"
      end
      raise InvalidCertification, "Cluster handoff identity is invalid" unless
        handoff.cluster_id.positive? && handoff.composition_version.positive?
    end

    def persist_failure_without_masking(handoff, original_error)
      return unless handoff&.persisted? && handoff.status == "processing"

      handoff.fail!(error_class: original_error.class.name)
    rescue StandardError => persistence_error
      @logger.error(
        "[cluster_actor_profile_dispatch] failure_persistence_failed " \
        "handoff_id=#{handoff.id} error_class=#{persistence_error.class.name}"
      )
    end

    def completed_result(handoff, actor_result)
      {
        handoff_id: handoff.id,
        cluster_id: handoff.cluster_id,
        composition_version: handoff.composition_version,
        status: "completed",
        actor_profile_status: actor_result.fetch(:status)
      }
    end

    def failed_result(handoff, actor_result)
      {
        handoff_id: handoff.id,
        cluster_id: handoff.cluster_id,
        composition_version: handoff.composition_version,
        status: "failed",
        actor_profile_status: actor_result.fetch(:status),
        reason: actor_result[:reason]
      }
    end
  end
end
