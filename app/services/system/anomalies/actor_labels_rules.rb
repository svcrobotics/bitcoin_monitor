# frozen_string_literal: true

module System
  module Anomalies
    module ActorLabelsRules
      module_function

      def call(context:)
        control =
          context[:actor_labels_control] || {}

        anomalies = []

        if control[:worker_present] == true &&
           control[:worker_write_observed] != true
          anomalies << Base.anomaly(
            code: "actor_labels_write_capability_unobserved",
            module_name: "actor_labels",
            severity: "warning",
            title: "ActorLabels n'a pas encore confirmé sa capacité d'écriture",
            facts: {
              worker_present: true,
              queue_name: control[:queue_name]
            },
            fingerprint: "actor_labels:write_capability_unobserved",
            confirmation_observations: 2
          )
        elsif control[:worker_write_observed] == true &&
              control[:worker_write_status_fresh] != true
          anomalies << Base.anomaly(
            code: "actor_labels_write_capability_stale",
            module_name: "actor_labels",
            severity: "warning",
            title: "La preuve d'écriture ActorLabels est expirée",
            facts: {
              observed_at: control[:worker_status_observed_at]
            }.compact,
            fingerprint: "actor_labels:write_capability_stale"
          )
        end

        anomalies
      end
    end
  end
end
