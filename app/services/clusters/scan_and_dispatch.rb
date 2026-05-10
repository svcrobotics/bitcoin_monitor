# frozen_string_literal: true

require "sidekiq/api"

module Clusters
  class ScanAndDispatch
    REFRESH_QUEUE = "p3_clusters_refresh"

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(**kwargs)
      @kwargs = kwargs
    end

    def call
      result = ClusterScanner.call(**kwargs.merge(refresh: false))

      if Clusters::DirtyClusterQueue.size.positive? && !refresh_already_pending?
        Clusters::RefreshDirtyClustersJob.perform_later
      end

      result
    end

    private

    attr_reader :kwargs

    def refresh_already_pending?
      queue_has_job?(REFRESH_QUEUE, "Clusters::RefreshDirtyClustersJob") ||
        queue_has_job?("default", "Clusters::RefreshDirtyClustersJob")
    end

    def queue_has_job?(queue_name, klass_name)
      Sidekiq::Queue.new(queue_name).any? do |job|
        job.klass.to_s == klass_name ||
          job.display_class.to_s == klass_name
      end
    rescue StandardError
      false
    end
  end
end