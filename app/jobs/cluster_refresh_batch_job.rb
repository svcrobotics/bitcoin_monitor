# frozen_string_literal: true

class ClusterRefreshBatchJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 50

  def perform(cluster_ids)
    ids = Array(cluster_ids).compact.uniq
    return if ids.empty?

    ids.each_slice(BATCH_SIZE) do |slice|
      Clusters::DirtyClusterRefresher.call(cluster_ids: slice)
    end
  end
end
