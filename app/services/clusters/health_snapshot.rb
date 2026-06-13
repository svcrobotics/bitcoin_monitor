# frozen_string_literal: true

module Clusters
  class HealthSnapshot
    CLUSTER_QUEUES = %w[
      p3_clusters_scan
      p3_clusters
      p3_clusters_refresh
      p3_actor_profile_light
      p3_actor_profile_heavy
    ].freeze

    def self.call
      new.call
    end

    def call
      best = BlockBufferModel.where(status: "processed").maximum(:height).to_i

      cluster_input_max_height = ClusterInput.maximum(:block_height).to_i
      cluster_input_max_spent = ClusterInput.maximum(:spent_block_height).to_i

      scanner_cursor = ScannerCursor.find_by(name: "cluster_scan")&.last_blockheight.to_i

      {
        module: "cluster_health",
        source: "cluster_health_snapshot",
        generated_at: Time.current,

        status: status(best, cluster_input_max_spent, scanner_cursor, coverage[:btc_coverage_pct]),

        sync: {
          best_height: best,
          cluster_input_max_height: cluster_input_max_height,
          cluster_input_max_spent: cluster_input_max_spent,
          scanner_cursor: scanner_cursor,
          input_lag: [best - cluster_input_max_spent, 0].max,
          spent_lag: [best - cluster_input_max_spent, 0].max,
          scanner_lag: [best - scanner_cursor, 0].max
        },

        counts: {
          cluster_inputs: ClusterInput.maximum(:id).to_i,
          clusters: Cluster.maximum(:id).to_i,
          addresses: Address.maximum(:id).to_i,
          addresses_clustered_sample: Address.where.not(cluster_id: nil).limit(1_000).count,
          actor_profiles: ActorProfile.maximum(:id).to_i
        },

        activity: {
          last_cluster_input_at: ClusterInput.maximum(:created_at),
          last_address_updated_at: Address.where.not(cluster_id: nil).maximum(:updated_at),
          last_cluster_processed_at: ClusterInput.maximum(:cluster_processed_at),
          last_actor_profile_at: ActorProfile.maximum(:updated_at)
        },

        coverage: coverage,
        audit: Clusters::RecentBlocksAudit.call(limit: 10),
        top_nil_cluster_addresses: top_nil_cluster_addresses,
        top_unknown_clusters: top_unknown_clusters,
        queues: sidekiq_queues,
        workers: cluster_workers
      }
    end

    private

    def status(best, cluster_input_max_spent, scanner_cursor, btc_coverage_pct)
      input_lag = [best - cluster_input_max_spent, 0].max
      scanner_lag = [best - scanner_cursor, 0].max

      return "critical" if input_lag > 20 || scanner_lag > 50
      return "critical" if btc_coverage_pct.to_f < 50

      return "warning" if input_lag > 5 || scanner_lag > 10
      return "warning" if btc_coverage_pct.to_f < 90

      "healthy"
    end

    def recent_scope
      to_height = ClusterInput.maximum(:block_height).to_i
      from_height = [to_height - 10, 0].max

      ClusterInput.where(block_height: from_height..to_height)
    end

    def nil_cluster_scope
      recent_scope
        .joins("LEFT JOIN addresses ON addresses.address = cluster_inputs.address")
        .where(addresses: { cluster_id: nil })
    end

    def clustered_scope
      recent_scope
        .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
        .where.not(addresses: { cluster_id: nil })
    end

    def coverage
      total_btc = recent_scope.sum(:amount_btc).to_d
      nil_btc = nil_cluster_scope.sum(:amount_btc).to_d
      clustered_btc = total_btc - nil_btc

      {
        window_blocks: 10,
        total_inputs: recent_scope.count,
        total_btc: total_btc.to_f,
        clustered_btc: clustered_btc.to_f,
        nil_cluster_btc: nil_btc.to_f,
        btc_coverage_pct: pct(clustered_btc, total_btc),
        nil_cluster_inputs: nil_cluster_scope.count,
        addresses_total: Address.count,
        addresses_nil_cluster: Address.where(cluster_id: nil).count
      }
    end

    def top_nil_cluster_addresses
      nil_cluster_scope
        .group("cluster_inputs.address")
        .order(Arel.sql("SUM(cluster_inputs.amount_btc) DESC"))
        .limit(20)
        .sum(:amount_btc)
    end

    def top_unknown_clusters
      clustered_scope
        .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
        .group("addresses.cluster_id")
        .order(Arel.sql("SUM(cluster_inputs.amount_btc) DESC"))
        .limit(20)
        .sum(:amount_btc)
    end

    def pct(value, total)
      total = total.to_d
      value = value.to_d

      return 0.0 if total.zero?

      ((value / total) * 100).round(2).to_f
    end

    def sidekiq_queues
      require "sidekiq/api"

      CLUSTER_QUEUES.to_h do |name|
        [name, Sidekiq::Queue.new(name).size]
      end
    rescue StandardError => e
      { error: e.message }
    end

    def cluster_workers
      require "sidekiq/api"

      Sidekiq::Workers.new.map do |_process_id, _thread_id, work|
        h = work.instance_variable_get(:@hsh)
        payload = JSON.parse(h["payload"]) rescue {}

        {
          queue: h["queue"],
          klass: payload["class"],
          args: payload["args"]
        }
      end.select do |w|
        CLUSTER_QUEUES.include?(w[:queue])
      end
    rescue StandardError => e
      [{ error: e.message }]
    end
  end
end
