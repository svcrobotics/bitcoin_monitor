# frozen_string_literal: true

class ClusterRefreshDispatchJob < ApplicationJob
  queue_as :p3_clusters

  BATCH_SIZE = 50

  def perform(cluster_ids)
    ids = Array(cluster_ids).compact.uniq
    return if ids.empty?

    ids.each_slice(BATCH_SIZE) do |slice|
      ClusterRefreshJob.perform_later(slice)
    end
  end
end
