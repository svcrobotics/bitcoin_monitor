# frozen_string_literal: true

module Clusters
  class RefreshDirtyClustersJob < ApplicationJob
    queue_as :p3_clusters_refresh

    def perform(cluster_ids = nil)
      layer1_lag = Blockchain::State::Layer1Lag.call

      if layer1_lag > Integer(ENV.fetch("CLUSTER_REFRESH_SKIP_IF_LAYER1_LAG_GT", "5"))
        Rails.logger.info("[cluster_refresh] skip layer1_lag=#{layer1_lag}")
        return { ok: true, skipped: true, reason: "layer1_lag", layer1_lag: layer1_lag }
      end

      cluster_ids =
        if cluster_ids.present?
          Array(cluster_ids).map(&:to_i).uniq
        else
          Clusters::DirtyClusterQueue.pop(limit: Integer(ENV.fetch("CLUSTER_REFRESH_BATCH_SIZE", "500")))
        end

      return { ok: true, skipped: true, reason: "no_dirty_clusters" } if cluster_ids.empty?

      Clusters::DirtyClusterRefresher.call(cluster_ids: cluster_ids)
    end
  end
end