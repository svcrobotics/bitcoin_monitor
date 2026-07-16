# frozen_string_literal: true

module System
  module Anomalies
    module ActorProfileRules
      module_function

      MODULE_NAME = "actor_profiles_strict"
      SOURCE = "canonical_postgresql_chain"
      AVAILABLE_STATUSES = %w[healthy syncing warning].freeze

      def call(context:)
        health = context[:actor_profile_health]
        reason = critical_reason(health)

        return [] unless reason

        [
          Base.anomaly(
            code: "actor_profile_strict_health_critical",
            module_name: "actor_profile",
            severity: "critical",
            title: "ActorProfile strict signale un état critique",
            facts: critical_facts(health, reason),
            fingerprint: "actor_profile:strict_health_critical:#{reason}"
          )
        ]
      end

      def critical_reason(health)
        return "snapshot_invalid" unless canonical_identity?(health)
        return "snapshot_unavailable" if health[:available] != true || health[:status].to_s == "unavailable"
        return "snapshot_invalid" unless AVAILABLE_STATUSES.include?(health[:status].to_s)
        return "snapshot_invalid" unless valid_handoff_counts?(health)

        failed = health.dig(:handoffs, :failed)
        stale = health.dig(:handoffs, :stale)

        return "failed_and_stale_handoffs" if failed.positive? && stale.positive?
        return "failed_handoffs" if failed.positive?
        return "stale_handoffs" if stale.positive?

        nil
      end

      def canonical_identity?(health)
        health.is_a?(Hash) &&
          health[:module].to_s == MODULE_NAME &&
          health[:source].to_s == SOURCE
      end

      def valid_handoff_counts?(health)
        handoffs = health[:handoffs]
        return false unless handoffs.is_a?(Hash)

        %i[failed stale].all? do |key|
          handoffs[key].is_a?(Integer) && handoffs[key] >= 0
        end
      end

      def critical_facts(health, reason)
        {
          reason: reason,
          status: health.is_a?(Hash) ? health[:status] : nil,
          available: health.is_a?(Hash) ? health[:available] : nil,
          failed_handoffs: health.is_a?(Hash) ? health.dig(:handoffs, :failed) : nil,
          stale_handoffs: health.is_a?(Hash) ? health.dig(:handoffs, :stale) : nil,
          oldest_handoff_age_seconds:
            health.is_a?(Hash) ? health.dig(:handoffs, :oldest_age_seconds) : nil
        }.compact
      end
    end
  end
end
