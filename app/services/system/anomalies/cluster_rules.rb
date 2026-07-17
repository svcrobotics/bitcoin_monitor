# frozen_string_literal: true

module System
  module Anomalies
    module ClusterRules
      module_function

      CRITICAL_LAG_BLOCKS = 20

      def call(context:)
        pipeline =
          context[:pipeline] || {}
        health =
          context[:cluster_health] || {}
        cluster =
          pipeline[:cluster] || {}

        anomalies = []

        if health[:status].to_s == "critical"
          anomalies << Base.anomaly(
            code: "cluster_health_critical",
            module_name: "cluster",
            severity: "critical",
            title: "Cluster signale un état critique",
            facts: {
              status: health[:status],
              issues: Array(health[:issues]).first(5),
              lag_blocks: cluster[:lag]
            },
            fingerprint: "cluster:health_critical"
          )
        end

        lag =
          cluster[:lag].to_i

        if lag > CRITICAL_LAG_BLOCKS
          anomalies << Base.anomaly(
            code: "cluster_lag_critical",
            module_name: "cluster",
            severity: "critical",
            title: "Cluster est très en retard",
            facts: {
              lag_blocks: lag,
              cluster_height: cluster[:processed_height],
              layer1_height:
                pipeline.dig(:layer1, :processed_height)
            }.compact,
            fingerprint: "cluster:lag_critical"
          )
        elsif lag > Layer1::HistoricalWorkConfig.max_cluster_lag_blocks &&
              cluster[:processing] != true
          anomalies << Base.anomaly(
            code: "cluster_lag_warning",
            module_name: "cluster",
            severity: "warning",
            title: "Cluster a du retard sans traitement actif",
            facts: {
              lag_blocks: lag,
              budget_blocks:
                Layer1::HistoricalWorkConfig.max_cluster_lag_blocks
            },
            fingerprint: "cluster:lag_warning",
            confirmation_observations: 2
          )
        end

        anomalies
      end
    end
  end
end
