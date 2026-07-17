# frozen_string_literal: true

module System
  module Anomalies
    module InfrastructureRules
      module_function

      def call(context:)
        pipeline =
          context[:pipeline] || {}

        anomalies = []

        unless pipeline.dig(:bitcoin_core, :available) == true
          anomalies << Base.anomaly(
            code: "bitcoin_core_unavailable",
            module_name: "infrastructure",
            severity: "critical",
            title: "Bitcoin Core est inaccessible",
            facts: {
              error: pipeline.dig(:bitcoin_core, :error)
            }.compact,
            fingerprint: "infrastructure:bitcoin_core_unavailable"
          )
        end

        if pipeline[:error].present?
          anomalies << Base.anomaly(
            code: "pipeline_snapshot_unavailable",
            module_name: "pipeline",
            severity: "critical",
            title: "Le snapshot du pipeline est indisponible",
            facts: {
              error: pipeline[:error]
            },
            fingerprint: "pipeline:snapshot_unavailable"
          )
        end

        anomalies
      end
    end
  end
end
