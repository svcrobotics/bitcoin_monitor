# frozen_string_literal: true

module Clusters
  class ActorProfileHandoffDispatchJob < ApplicationJob
    queue_as :actor_profile_strict

    DEFAULT_LIMIT = 10
    MAX_LIMIT = 100
    RESCHEDULE_DELAY = 5.seconds

    def perform(limit: DEFAULT_LIMIT)
      decision = System::PipelineController.decision(:actor_profile)
      unless decision.is_a?(Hash) && [true, false].include?(decision[:allowed])
        raise "ActorProfile PipelineController returned an invalid decision"
      end

      unless decision[:allowed]
        return {
          ok: true,
          status: "skipped",
          reason: "pipeline_controller_refused",
          decision: decision
        }
      end

      bounded_limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      result = Clusters::ActorProfileHandoffDispatcher.call(limit: bounded_limit)
      if Clusters::ActorProfileHandoffDispatcher.work_available?
        self.class.set(wait: RESCHEDULE_DELAY).perform_later(limit: bounded_limit)
      end
      result
    end
  end
end
