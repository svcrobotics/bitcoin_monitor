# frozen_string_literal: true

module Clusters
  class RefreshDirtyClustersJob < ApplicationJob
    queue_as :p3_clusters_refresh

    def perform(cluster_ids)
      layer1_lag = BlockBufferModel.maximum(:height).to_i -
             BlockBufferModel.where(status: "processed").maximum(:height).to_i

      if layer1_lag > Integer(ENV.fetch("CLUSTER_REFRESH_SKIP_IF_LAYER1_LAG_GT", "5"))
        Rails.logger.info("[cluster_refresh] skip layer1_lag=#{layer1_lag}")
        return { ok: true, skipped: true, reason: "layer1_lag", layer1_lag: layer1_lag }
      end
      
      cluster_ids = Array(cluster_ids).map(&:to_i).uniq
      return if cluster_ids.empty?

      Clusters::DirtyClusterRefresher.call(cluster_ids: cluster_ids)
    end
  end
end
