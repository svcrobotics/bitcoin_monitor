# frozen_string_literal: true
module ActorLabels
  class BuildDispatchJob < ApplicationJob
    queue_as :actor_labels_strict
    DEFAULT_LIMIT = BuildDispatcher::DEFAULT_LIMIT
    MAX_LIMIT = BuildDispatcher::MAX_LIMIT
    RESCHEDULE_DELAY = 5.seconds
    def perform(limit: DEFAULT_LIMIT)
      decision = System::PipelineController.decision(:actor_labels)
      raise "ActorLabels PipelineController returned an invalid decision" unless
        decision.is_a?(Hash) && [true, false].include?(decision[:allowed])
      return { ok: true, status: "skipped", reason: "pipeline_controller_refused" } unless decision[:allowed]
      bounded = [[Integer(limit), 1].max, MAX_LIMIT].min
      result = BuildDispatcher.call(limit: bounded)
      self.class.set(wait: RESCHEDULE_DELAY).perform_later(limit: bounded) if BuildDispatcher.work_available?
      result
    end
  end
end
