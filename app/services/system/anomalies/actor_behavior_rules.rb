# frozen_string_literal: true

module System
  module Anomalies
    module ActorBehaviorRules
      module_function

      def call(context:)
        control =
          context[:actor_behavior_control] || {}
        decision =
          context.dig(:decisions, :actor_behavior) || {}

        anomalies = []

        if control[:stale_running_run] == true
          anomalies << Base.anomaly(
            code: "actor_behavior_run_stale",
            module_name: "actor_behavior",
            severity: "warning",
            title: "ActorBehavior a un run stale",
            facts: {
              last_run_status: control[:last_run_status],
              last_run_finished_at: control[:last_run_finished_at]
            }.compact,
            fingerprint: "actor_behavior:run_stale"
          )
        end

        if control[:auto_enabled] == true &&
           control[:work_available] == true &&
           decision[:state] == :run &&
           decision[:allowed] == true &&
           control[:batch_running] != true &&
           control[:cooldown_active] != true
          anomalies << Base.anomaly(
            code: "actor_behavior_work_waiting",
            module_name: "actor_behavior",
            severity: "warning",
            title: "ActorBehavior a du travail disponible",
            facts: {
              missing_work_available:
                control[:missing_work_available],
              stale_work_available:
                control[:stale_work_available],
              last_run_status:
                control[:last_run_status]
            },
            fingerprint: "actor_behavior:work_waiting",
            confirmation_observations: 2
          )
        end

        anomalies
      end
    end
  end
end
