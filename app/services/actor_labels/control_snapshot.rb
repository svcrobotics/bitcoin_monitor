# frozen_string_literal: true
module ActorLabels
  class ControlSnapshot
    QUEUE = "actor_labels_strict"
    def self.call
      require "sidekiq/api"
      queue = Sidekiq::Queue.new(QUEUE)
      workers = Sidekiq::Workers.new.count { |_pid, _tid, work| work.dig("payload", "queue") == QUEUE }
      scheduled = Sidekiq::ScheduledSet.new.count { |job| job.queue == QUEUE }
      { source: "actor_label_handoffs", rule_version: CertifiedRuleSet::RULE_VERSION,
        required_behavior_version: ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,
        queue_name: QUEUE, queue_size: queue.size, scheduled_size: scheduled,
        worker_busy: workers.positive?, worker_present: workers.positive?, lock_present: false,
        cursor: nil, work_available: BuildDispatcher.work_available?,
        pending_for_labels: BuildDispatcher.claimable_scope.count,
        cooldown_active: false, cooldown_remaining_seconds: 0, next_eligible_at: nil,
        last_run_status: nil, last_run_finished_at: nil, last_runtime_ms: nil,
        sidekiq_available: true }
    rescue StandardError
      { source: "actor_label_handoffs", rule_version: CertifiedRuleSet::RULE_VERSION,
        required_behavior_version: ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,
        queue_name: QUEUE, queue_size: nil, scheduled_size: nil, worker_busy: nil,
        worker_present: nil, lock_present: false, cursor: nil,
        work_available: BuildDispatcher.work_available?,
        pending_for_labels: BuildDispatcher.claimable_scope.count,
        cooldown_active: false, sidekiq_available: false }
    end
  end
end
