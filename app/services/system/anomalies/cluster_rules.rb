# frozen_string_literal: true

module System
  module Anomalies
    module ClusterRules
      module_function

      def call(context:)
        health = context[:cluster_health] || {}

        return [] unless health[:status].to_s == "critical"

        [
          Base.anomaly(
            code: "cluster_health_critical",
            module_name: "cluster",
            severity: "critical",
            title: "Cluster signale un état critique",
            facts: {
              status: health[:status],
              layer1_tip: health[:layer1_tip],
              cluster_tip: health[:cluster_tip],
              cluster_lag: health[:cluster_lag],
              failed_handoffs: health.dig(:handoffs, :failed),
              stale_handoffs: health.dig(:handoffs, :stale_claims)
            }.compact,
            fingerprint: "cluster:health_critical"
          )
        ]
      end
    end
  end
end
