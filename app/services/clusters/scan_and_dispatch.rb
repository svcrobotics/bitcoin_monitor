# frozen_string_literal: true

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

      dirty_cluster_ids = Array(result[:dirty_cluster_ids])

      if dirty_cluster_ids.any?
        ClusterRefreshDispatchJob.perform_later(dirty_cluster_ids)
      end

      result
    end

    private

    attr_reader :kwargs
  end
end