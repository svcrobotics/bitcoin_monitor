# frozen_string_literal: true
module ActorLabels
  class BuildDispatcher
    DEFAULT_LIMIT = 10; MAX_LIMIT = 100; MAX_ATTEMPTS = 5; STALE_AFTER = 15.minutes
    class UnexpectedResult < StandardError; end
    def self.call(limit: DEFAULT_LIMIT, now: Time.current) = new(limit:, now:).call
    def self.claimable_scope(now: Time.current)
      ActorLabelHandoff.where(status: %w[pending failed]).where("attempts < ?", MAX_ATTEMPTS)
        .or(ActorLabelHandoff.where(status: "processing").where("attempts < ?", MAX_ATTEMPTS)
          .where("claimed_at < ?", now - STALE_AFTER))
    end
    def self.work_available?(now: Time.current) = claimable_scope(now:).exists?
    def initialize(limit:, now:, logger: Rails.logger)
      @limit = [[Integer(limit), 1].max, MAX_LIMIT].min; @now = now; @logger = logger
    end
    def call
      handoffs = claim; results = handoffs.map { |handoff| process(handoff) }
      { ok: results.none? { |r| r[:status] == "failed" }, claimed: handoffs.size,
        completed: results.count { |r| r[:status] == "completed" },
        failed: results.count { |r| r[:status] == "failed" }, results: results }
    end
    private
    def claim
      claimed = []
      ApplicationRecord.transaction(requires_new: true) do
        self.class.claimable_scope(now: @now).order(:source_height, :cluster_id, :id)
          .limit(@limit).lock("FOR UPDATE SKIP LOCKED").each do |handoff|
            handoff.claim!(at: @now); claimed << handoff
          end
      end
      claimed
    end
    def process(handoff)
      result = StrictEvaluateFromBehavior.call(cluster_id: handoff.cluster_id,
        cluster_composition_version: handoff.cluster_composition_version,
        profile_version: handoff.profile_version, source_height: handoff.source_height,
        source_hash: handoff.source_hash, behavior_version: handoff.behavior_version,
        behavior_snapshot_id: handoff.actor_behavior_snapshot_id,
        rule_version: handoff.rule_version)
      if %w[evaluated already_current superseded].include?(result[:status])
        handoff.complete!(at: Time.current)
        { handoff_id: handoff.id, status: "completed", evaluation_status: result[:status] }
      elsif result[:status] == "refused"
        handoff.fail!(error_class: "ActorLabelSourceRefused")
        { handoff_id: handoff.id, status: "failed", evaluation_status: "refused" }
      else
        raise UnexpectedResult, "ActorLabel evaluator returned a non-terminal result"
      end
    rescue StandardError => original
      begin
        handoff.fail!(error_class: original.class.name) if handoff&.status == "processing"
      rescue StandardError => secondary
        @logger.error("[actor_label_dispatch] failure_persistence_failed handoff_id=#{handoff.id} error_class=#{secondary.class.name}")
      end
      raise original
    end
  end
end
