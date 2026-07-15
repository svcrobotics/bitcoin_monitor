# frozen_string_literal: true

module Clusters
  class ActorProfileHandoffDispatchJob < ApplicationJob
    # Le consommateur Cluster strict est le déclencheur durable déjà actif.
    # Le traitement reste borné et l'outbox demeure la source de reprise.
    queue_as :cluster_strict

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
