# frozen_string_literal: true

module Clusters
  class DirtyClusterRefresher
    DEFAULT_BATCH_SIZE = Integer(ENV.fetch("DIRTY_CLUSTER_REFRESH_BATCH_SIZE", "500"))

    def self.call(cluster_ids:)
      new(cluster_ids: cluster_ids).call
    end

    def initialize(cluster_ids:)
      @cluster_ids = Array(cluster_ids).compact.map(&:to_i).uniq
    end

    def call
      return 0 if cluster_ids.empty?

      started_at = monotonic_ms
      refreshed = 0
      failed = 0

      puts "[cluster_refresh] start count=#{cluster_ids.size}"

      Cluster.where(id: cluster_ids).find_each(batch_size: DEFAULT_BATCH_SIZE) do |cluster|
        cluster_started_at = monotonic_ms

        cluster.recalculate_stats!
        ClusterAggregator.call(cluster)

        refreshed += 1

        if (refreshed % 50).zero?
          puts "[cluster_refresh] progress refreshed=#{refreshed}/#{cluster_ids.size}"
        end
      rescue StandardError => e
        failed += 1

        puts(
          "[cluster_refresh] failed cluster_id=#{cluster.id} " \
          "duration_ms=#{monotonic_ms - cluster_started_at} " \
          "error=#{e.class}: #{e.message}"
        )
      end

      duration_ms = monotonic_ms - started_at

      puts(
        "[cluster_refresh] done refreshed=#{refreshed} " \
        "failed=#{failed} duration_ms=#{duration_ms}"
      )

      refreshed
    end

    private

    attr_reader :cluster_ids

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
    end
  end
end