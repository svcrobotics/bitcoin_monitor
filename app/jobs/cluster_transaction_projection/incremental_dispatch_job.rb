# frozen_string_literal: true

module ClusterTransactionProjection
  class IncrementalDispatchJob < ApplicationJob
    queue_as :cluster_strict

    # CTP shares cluster_strict with the canonical Cluster sync. No dedicated
    # runtime budget exists yet, so one generation per invocation is the safe
    # bounded default and maximum.
    DEFAULT_LIMIT = 1
    MAX_LIMIT = 1

    def perform(limit: DEFAULT_LIMIT)
      decision = System::PipelineController.decision(:cluster)
      unless decision.is_a?(Hash) && [true, false].include?(decision[:allowed])
        raise "Cluster PipelineController returned an invalid decision"
      end
      return skipped(decision) unless decision[:allowed]

      bounded_limit = normalized_limit(limit)
      raise ArgumentError, "limit must be positive" unless bounded_limit.positive?
      raise ArgumentError, "limit exceeds #{MAX_LIMIT}" if bounded_limit > MAX_LIMIT

      IncrementalDispatcher.call(limit: bounded_limit)
    end

    private

    def normalized_limit(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "limit must be an integer"
    end

    def skipped(decision)
      {
        ok: true,
        status: "skipped",
        reason: "pipeline_controller_refused",
        decision: decision
      }
    end
  end
end
