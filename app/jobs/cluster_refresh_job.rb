# app/jobs/cluster_refresh_job.rb
# frozen_string_literal: true

class ClusterRefreshJob < ApplicationJob
  queue_as :p3_clusters

  def perform(cluster_ids)
    ids = Array(cluster_ids).compact.uniq
    return if ids.empty?

    Clusters::DirtyClusterRefresher.call(cluster_ids: ids)
  end
end