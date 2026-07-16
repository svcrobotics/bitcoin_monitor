# frozen_string_literal: true

module ActorProfiles
  class BuildDispatchJob < ApplicationJob
    queue_as :actor_profile_strict

    DEFAULT_LIMIT = BuildDispatcher::DEFAULT_LIMIT
    MAX_LIMIT = BuildDispatcher::MAX_LIMIT
    RESCHEDULE_DELAY = 5.seconds

    def perform(limit: DEFAULT_LIMIT)
      decision = System::PipelineController.decision(:actor_profile)
      unless decision.is_a?(Hash) && [true, false].include?(decision[:allowed])
        raise "ActorProfile PipelineController returned an invalid decision"
      end
      return { ok: true, status: "skipped", reason: "pipeline_controller_refused" } unless
        decision[:allowed]

      bounded_limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      result = BuildDispatcher.call(limit: bounded_limit)
      if BuildDispatcher.work_available?
        self.class.set(wait: RESCHEDULE_DELAY).perform_later(limit: bounded_limit)
      end
      result
    end
  end
end
