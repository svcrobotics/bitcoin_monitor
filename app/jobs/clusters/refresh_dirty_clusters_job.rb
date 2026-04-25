# frozen_string_literal: true

module Clusters
  class RefreshDirtyClustersJob < ApplicationJob
    queue_as :default

    def perform(cluster_ids)
      cluster_ids = Array(cluster_ids).map(&:to_i).uniq
      return if cluster_ids.empty?

      Clusters::DirtyClusterRefresher.call(cluster_ids: cluster_ids)
    end
  end
end
