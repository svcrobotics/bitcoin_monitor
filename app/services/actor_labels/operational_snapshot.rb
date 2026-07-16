# frozen_string_literal: true
module ActorLabels
  class OperationalSnapshot
    def self.call
      eligible = ActorBehaviorSnapshot.where(status: "certified", certification_scope: "strict")
      evaluations = ActorLabelEvaluation.where(status: "certified", certification_scope: "strict")
      handoffs = ActorLabelHandoff.group(:status).count
      current_ids = evaluations.where(rule_version: CertifiedRuleSet::RULE_VERSION)
        .select(:actor_behavior_snapshot_id)
      missing = eligible.where.not(id: current_ids).count
      positives = ActorLabel.where(source: CertifiedRuleSet::SOURCE,
        rule_version: CertifiedRuleSet::RULE_VERSION).group(:label).count
      control = ControlSnapshot.call
      total = eligible.count
      { status: control[:sidekiq_available] == false ? "unavailable" : "available",
        rule_version: CertifiedRuleSet::RULE_VERSION,
        active_rules: CertifiedRuleSet::ACTIVE_RULES,
        deferred_rules: CertifiedRuleSet::DEFERRED_RULES,
        behavior_eligible: total, evaluations_certified: evaluations.count,
        evaluations_missing: missing,
        coverage: total.zero? ? nil : ((total - missing).to_f / total),
        positive_by_rule: positives,
        negative_by_rule: negative_counts(evaluations),
        handoffs_pending: handoffs.fetch("pending", 0),
        handoffs_processing: handoffs.fetch("processing", 0),
        handoffs_failed: handoffs.fetch("failed", 0),
        stale_claims: ActorLabelHandoff.where(status: "processing")
          .where("claimed_at < ?", Time.current - BuildDispatcher::STALE_AFTER).count,
        oldest_backlog_age_seconds: oldest_age,
        queue_size: control[:queue_size], scheduled_size: control[:scheduled_size],
        worker_busy: control[:worker_busy], sidekiq_available: control[:sidekiq_available],
        generated_at: Time.current }
    rescue ActiveRecord::ActiveRecordError
      { status: "unavailable", database_available: false, queue_size: nil,
        evaluations_certified: nil, evaluations_missing: nil, coverage: nil }
    end
    def self.negative_counts(scope)
      CertifiedRuleSet::ACTIVE_RULES.to_h do |rule|
        [rule, scope.where("rule_results ->> ? = ?", rule, "false").count]
      end
    end
    def self.oldest_age
      oldest = ActorLabelHandoff.where(status: %w[pending processing failed]).minimum(:created_at)
      oldest ? [Time.current - oldest, 0].max : nil
    end
    private_class_method :negative_counts, :oldest_age
  end
end
