# frozen_string_literal: true

module System
  module Anomalies
    module ActorLabelsRules
      module_function

      SOURCE = "actor_labels_strict_health_snapshot_v2"
      VALID_STATUSES = %w[healthy syncing dry_run critical].freeze

      def call(context:)
        health = context[:actor_labels_health]
        reason = critical_reason(health)

        return [] unless reason

        [
          Base.anomaly(
            code: "actor_labels_strict_integrity_critical",
            module_name: "actor_labels",
            severity: "critical",
            title: "ActorLabels strict signale une divergence certifiée",
            facts: critical_facts(health, reason),
            fingerprint: "actor_labels:strict_integrity_critical:#{reason}"
          )
        ]
      end

      def critical_reason(health)
        return "snapshot_missing" if health.nil?
        return "snapshot_invalid" unless valid_snapshot?(health)

        profiles = health[:actor_profiles]

        return "certified_scope_mismatch" if profiles[:certified_scope_matches] == false

        nil
      end

      def valid_snapshot?(health)
        return false unless health.is_a?(Hash)
        return false unless health[:source].to_s == SOURCE
        return false unless VALID_STATUSES.include?(health[:status].to_s)
        return false if health[:rule_version].to_s.empty?

        profiles = health[:actor_profiles]
        return false unless profiles.is_a?(Hash)
        return false unless [true, false].include?(profiles[:certified_scope_matches])

        %i[certified expected_certified].all? do |key|
          profiles[key].is_a?(Integer) && profiles[key] >= 0
        end
      end

      def critical_facts(health, reason)
        profiles = health.is_a?(Hash) && health[:actor_profiles].is_a?(Hash) ? health[:actor_profiles] : {}

        {
          reason: reason,
          source: health.is_a?(Hash) ? health[:source] : nil,
          status: health.is_a?(Hash) ? health[:status] : nil,
          rule_version: health.is_a?(Hash) ? health[:rule_version] : nil,
          certified_profiles: profiles[:certified],
          expected_certified_profiles: profiles[:expected_certified]
        }.compact
      end
    end
  end
end
