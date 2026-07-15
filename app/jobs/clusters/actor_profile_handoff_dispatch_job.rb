# frozen_string_literal: true

module Clusters
  class ActorProfileHandoffDispatchJob < ApplicationJob
    queue_as :actor_profile_strict

    DEFAULT_LIMIT = 10
    RESCHEDULE_DELAY = 1.second

    def perform(limit: DEFAULT_LIMIT)
      result = Clusters::ActorProfileHandoffDispatcher.call(limit: limit)
      if Clusters::ActorProfileHandoffDispatcher.work_available?
        self.class.set(wait: RESCHEDULE_DELAY).perform_later(limit: limit)
      end
      result
    end
  end
end
