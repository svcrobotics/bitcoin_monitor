# frozen_string_literal: true

module Clusters
  class ClusterInputOrchestratorJob
    include Sidekiq::Job

    sidekiq_options queue: :p3_clusters_scan, retry: 3

    def perform
      result = Clusters::ClusterInputOrchestrator.call

      Rails.logger.info(
        "[cluster_input_orchestrator_job] result=#{result.inspect}"
      )
    end
  end
end
