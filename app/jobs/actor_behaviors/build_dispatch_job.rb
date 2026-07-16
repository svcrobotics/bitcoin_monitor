# frozen_string_literal: true

module ActorBehaviors
  class BuildDispatchJob < ApplicationJob
    queue_as :actor_behavior_strict

    DEFAULT_LIMIT = BuildDispatcher::DEFAULT_LIMIT
    MAX_LIMIT = BuildDispatcher::MAX_LIMIT
    RESCHEDULE_DELAY = 5.seconds

    def perform(limit: DEFAULT_LIMIT)
      decision = System::PipelineController.decision(:actor_behavior)
      unless decision.is_a?(Hash) && [true, false].include?(decision[:allowed])
        raise "ActorBehavior PipelineController returned an invalid decision"
      end
      return skipped unless decision[:allowed]

      bounded_limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      result = BuildDispatcher.call(limit: bounded_limit)
      if BuildDispatcher.work_available?
        self.class.set(wait: RESCHEDULE_DELAY).perform_later(limit: bounded_limit)
      end
      result
    end

    private

    def skipped
      { ok: true, status: "skipped", reason: "pipeline_controller_refused" }
    end
  end
end
