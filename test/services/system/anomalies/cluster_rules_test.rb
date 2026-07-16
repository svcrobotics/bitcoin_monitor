# frozen_string_literal: true

require "test_helper"

module System
  module Anomalies
    class ClusterRulesTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      test "returns no anomaly for a healthy strict snapshot" do
        anomalies = ClusterRules.call(
          context: {
            cluster_health: {
              status: "healthy",
              layer1_tip: 957_876,
              cluster_tip: 957_876,
              cluster_lag: 0,
              handoffs: {
                failed: 0,
                stale_claims: 0
              }
            }
          }
        )

        assert_empty anomalies
      end

      test "emits a critical anomaly from canonical strict health facts" do
        anomaly = ClusterRules.call(
          context: {
            cluster_health: {
              status: "critical",
              layer1_tip: 957_876,
              cluster_tip: 957_874,
              cluster_lag: 2,
              handoffs: {
                failed: 3,
                stale_claims: 1
              }
            }
          }
        ).sole.to_h

        assert_equal "cluster_health_critical", anomaly[:code]
        assert_equal "cluster", anomaly[:module]
        assert_equal "critical", anomaly[:severity]
        assert_equal "cluster:health_critical", anomaly[:fingerprint]
        assert_equal 957_876, anomaly.dig(:facts, :layer1_tip)
        assert_equal 957_874, anomaly.dig(:facts, :cluster_tip)
        assert_equal 2, anomaly.dig(:facts, :cluster_lag)
        assert_equal 3, anomaly.dig(:facts, :failed_handoffs)
        assert_equal 1, anomaly.dig(:facts, :stale_handoffs)
      end

      test "does not classify unavailable snapshots as certified critical facts" do
        anomalies = ClusterRules.call(
          context: {
            cluster_health: {
              status: "unavailable",
              database_available: false,
              error_class: "ActiveRecord::ConnectionNotEstablished"
            }
          }
        )

        assert_empty anomalies
      end
    end
  end
end
