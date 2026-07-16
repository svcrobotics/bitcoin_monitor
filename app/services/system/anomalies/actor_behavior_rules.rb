# frozen_string_literal: true

module System
  module Anomalies
    module ActorBehaviorRules
      module_function

      def call(context:)
        health = context[:actor_behavior_health]
        reason = critical_reason(health)

        return [] unless reason

        [
          Base.anomaly(
            code: "actor_behavior_strict_health_critical",
            module_name: "actor_behavior",
            severity: "critical",
            title: "ActorBehavior strict signale un état critique",
            facts: critical_facts(health, reason),
            fingerprint: "actor_behavior:strict_health_critical:#{reason}"
          )
        ]
      end

      def critical_reason(health)
        return "snapshot_invalid" unless health.is_a?(Hash)
        return "snapshot_unavailable" if health[:status].to_s == "unavailable"
        return "snapshot_invalid" unless health[:status].to_s == "available"
        return "snapshot_invalid" unless valid_handoff_counts?(health[:handoffs])

        failed = health.dig(:handoffs, :failed)
        stale = health.dig(:handoffs, :stale)

        return "failed_and_stale_handoffs" if failed.positive? && stale.positive?
        return "failed_handoffs" if failed.positive?
        return "stale_handoffs" if stale.positive?

        nil
      end

      def valid_handoff_counts?(handoffs)
        handoffs.is_a?(Hash) &&
          %i[failed stale].all? do |key|
            handoffs[key].is_a?(Integer) && handoffs[key] >= 0
          end
      end

      def critical_facts(health, reason)
        {
          reason: reason,
          status: health.is_a?(Hash) ? health[:status] : nil,
          failed_handoffs: health.is_a?(Hash) ? health.dig(:handoffs, :failed) : nil,
          stale_handoffs: health.is_a?(Hash) ? health.dig(:handoffs, :stale) : nil,
          oldest_handoff_age_seconds:
            health.is_a?(Hash) ? health.dig(:handoffs, :oldest_age_seconds) : nil
        }.compact
      end
    end
  end
end
