# frozen_string_literal: true

module System
  module Anomalies
    module ActorProfileRules
      module_function

      def call(context:)
        profile =
          context.dig(:pipeline, :actor_profile) || {}
        decision =
          context.dig(:decisions, :actor_profile) || {}

        return [] unless decision[:allowed] == true

        pending =
          profile[:pending_work].to_i

        return [] unless pending.positive?
        return [] if profile[:processing] == true
        return [] if profile[:strict_worker_busy] == true
        return [] if profile[:strict_queue_size].to_i.positive?

        [
          Base.anomaly(
            code: "actor_profile_backlog_idle",
            module_name: "actor_profile",
            severity: "warning",
            title: "ActorProfile a du travail sans traitement actif",
            facts: {
              pending_work: pending,
              checkpoint_height: profile[:checkpoint_height]
            }.compact,
            fingerprint: "actor_profile:backlog_idle",
            confirmation_observations: 2
          )
        ]
      end
    end
  end
end
