# frozen_string_literal: true
require "sidekiq/api"

module Clusters
  class ScanAndDispatch
    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(**kwargs)
      @kwargs = kwargs
    end

    def call
      result = ClusterScanner.call(**kwargs.merge(refresh: false))

      dirty_cluster_ids = Array(result[:dirty_cluster_ids]).compact.uniq

      if dirty_cluster_ids.any? && !refresh_already_pending?
        ClusterRefreshDispatchJob.perform_later(dirty_cluster_ids)
      end

      result
    end

    private

    attr_reader :kwargs

    def refresh_already_pending?
      queue_has_job?("default", "ClusterRefreshDispatchJob") ||
        queue_has_job?("default", "ClusterRefreshJob")
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