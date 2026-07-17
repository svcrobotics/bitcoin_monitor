# frozen_string_literal: true

module ActorLabels
  class StrictHealthSnapshot
    SOURCE = "actor_labels_strict_health_snapshot_v4"
    PHASE = "behavior_strict_v2"

    REQUIRED_BEHAVIOR_VERSION =
      ActorLabels::StrictRuleSet::BEHAVIOR_VERSION

    def self.call(
      behavior_snapshot: nil,
      control_snapshot: nil
    )
      new(
        behavior_snapshot: behavior_snapshot,
        control_snapshot: control_snapshot
      ).call
    end

    def initialize(
      behavior_snapshot: nil,
      control_snapshot: nil
    )
      @behavior_snapshot = behavior_snapshot
      @control_snapshot = control_snapshot
    end

    def call
      behavior =
        behavior_snapshot ||
        ActorBehaviors::StrictHealthSnapshot.call

      control =
        control_snapshot ||
        ActorLabels::ControlSnapshot.call

      strict_labels =
        ActorLabel.where(
          source: ActorLabels::StrictRuleSet::SOURCE
        )

      reasons =
        reasons_for(
          behavior: behavior,
          control: control
        )

      {
        status:
          status_for(reasons),
        phase: PHASE,
        ready: reasons.empty?,
        source: SOURCE,
        generated_at: Time.current,
        reasons: reasons,
        issues: [],

        pipeline: {
          mode: "active",
          source:
            ActorLabels::StrictRuleSet::SOURCE,
          rule_version:
            ActorLabels::StrictRuleSet::RULE_VERSION,
          required_behavior_version:
            REQUIRED_BEHAVIOR_VERSION,
          dependency: "actor_behaviors",
          dependency_status: behavior[:status].to_s,
          dependency_ready: behavior[:ready] == true,
          automation_enabled: true,

          # Compatibilité pour les consommateurs existants :
          # ce champ représente désormais l’écriture automatique.
          write_enabled:
            automatic_write_enabled?(control),

          automatic_write_enabled:
            automatic_write_enabled?(control),
          worker_write_enabled:
            control[:worker_write_enabled] == true,
          worker_write_observed:
            control[:worker_write_observed] == true,
          worker_write_status_fresh:
            control[:worker_write_status_fresh] == true,
          worker_write_status_observed_at:
            control[:worker_status_observed_at],

          # Le serveur web reste volontairement sans droit
          # d’écriture directe.
          local_write_enabled:
            local_write_enabled?,

          zero_labels_is_valid: true
        },

        actor_behaviors:
          behavior_payload(behavior),

        actor_labels: {
          total:
            strict_labels.count,
          strict_total:
            strict_labels.count,
          pending_for_labels:
            control[:pending_for_labels].to_i,
          evaluated_cursor:
            control[:cursor].to_i,
          by_label:
            strict_labels.group(:label).count,
          by_source:
            ActorLabel.group(:source).count
        },

        rules: {
          active:
            %w[
              whale_like
              whale_candidate
              exchange_like
              service_like
              etf_candidate
            ],
          connected: true,
          disabled:
            %w[
              etf_like
              retail_like
            ]
        },

        automation: {
          queue_name:
            control[:queue_name],
          queue_size:
            control[:queue_size].to_i,
          queue_latency:
            queue_latency(control[:queue_name]),
          scheduled_size:
            control[:scheduled_size].to_i,
          worker_present:
            control[:worker_present] == true,
          worker_busy:
            control[:worker_busy] == true,
          lock_present:
            control[:lock_present] == true,
          cooldown_active:
            control[:cooldown_active] == true,
          cooldown_remaining_seconds:
            control[:cooldown_remaining_seconds].to_i,
          next_eligible_at:
            control[:next_eligible_at],
          last_run_status:
            control[:last_run_status],
          last_run_finished_at:
            control[:last_run_finished_at],
          last_runtime_ms:
            control[:last_runtime_ms],
          last_run:
            control[:last_run] || {}
        }
      }
    end

    private

    attr_reader :behavior_snapshot, :control_snapshot

    def behavior_payload(behavior)
      operational =
        behavior[:operational] || {}

      {
        status: behavior[:status].to_s,
        phase: behavior[:phase].to_s,
        ready: behavior[:ready] == true,
        behavior_version:
          operational[:behavior_version].to_s,
        actor_profiles_certified:
          operational[:actor_profiles_certified].to_i,
        snapshots_total:
          operational[:snapshots_total].to_i,
        snapshots_current:
          operational[:snapshots_current].to_i,
        snapshots_missing:
          operational[:snapshots_missing].to_i,
        snapshots_stale:
          operational[:snapshots_stale].to_i,
        coverage_percent:
          operational[:coverage_percent].to_f,
        actor_profile_max_height:
          operational[:actor_profile_max_height].to_i,
        behavior_snapshot_max_height:
          operational[:behavior_snapshot_max_height].to_i,
        checkpoint_lag:
          operational[:checkpoint_lag].to_i,
        last_run_status:
          operational[:last_run_status].to_s,
        running_runs:
          operational[:running_runs].to_i
      }
    end

    def reasons_for(behavior:, control:)
      reasons = []

      unless behavior[:ready] == true ||
             control[:work_available] == true
        reasons << "actor_behavior_not_ready"
      end

      reasons << "actor_labels_queue_backlog" if control[:queue_size].to_i.positive?
      reasons << "actor_labels_worker_busy" if control[:worker_busy] == true
      reasons << "actor_labels_lock_present" if control[:lock_present] == true

      reasons.uniq
    end

    def status_for(reasons)
      return "active" if reasons.empty?
      return "processing" if reasons.include?("actor_labels_worker_busy")

      "waiting"
    end

    def automatic_write_enabled?(control)
      control[:worker_present] == true &&
        control[:worker_write_observed] == true &&
        control[:worker_write_status_fresh] == true &&
        control[:worker_write_enabled] == true
    end

    def local_write_enabled?
      ActiveModel::Type::Boolean.new.cast(
        ENV.fetch("ACTOR_LABEL_WRITE_ENABLED", "false")
      )
    end

    def queue_latency(queue_name)
      require "sidekiq/api"

      Sidekiq::Queue.new(queue_name).latency
    rescue StandardError
      0
    end
  end
end
