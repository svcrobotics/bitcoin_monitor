# frozen_string_literal: true

require "test_helper"

module System
  module Anomalies
    class ActorBehaviorRulesTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      test "returns no anomaly for a healthy strict snapshot" do
        assert_empty ActorBehaviorRules.call(
          context: {
            actor_behavior_health: strict_health
          }
        )
      end

      test "emits a stable critical anomaly for failed strict handoffs" do
        anomaly = ActorBehaviorRules.call(
          context: {
            actor_behavior_health: strict_health(
              handoffs: {
                failed: 2,
                stale: 0,
                oldest_age_seconds: 120
              }
            )
          }
        ).sole.to_h

        assert_equal "actor_behavior_strict_health_critical", anomaly[:code]
        assert_equal "critical", anomaly[:severity]
        assert_equal "failed_handoffs", anomaly.dig(:facts, :reason)
        assert_equal 2, anomaly.dig(:facts, :failed_handoffs)
        assert_equal 120, anomaly.dig(:facts, :oldest_handoff_age_seconds)
        assert_equal "actor_behavior:strict_health_critical:failed_handoffs", anomaly[:fingerprint]
      end

      test "fails closed for an unavailable strict snapshot" do
        anomaly = ActorBehaviorRules.call(
          context: {
            actor_behavior_health: {
              status: "unavailable",
              handoffs: nil
            }
          }
        ).sole.to_h

        assert_equal "critical", anomaly[:severity]
        assert_equal "snapshot_unavailable", anomaly.dig(:facts, :reason)
        assert_equal "actor_behavior:strict_health_critical:snapshot_unavailable", anomaly[:fingerprint]
      end

      test "fails closed for invalid snapshot data" do
        anomaly = ActorBehaviorRules.call(
          context: {
            actor_behavior_health: strict_health(
              handoffs: {
                failed: "2",
                stale: 0
              }
            )
          }
        ).sole.to_h

        assert_equal "critical", anomaly[:severity]
        assert_equal "snapshot_invalid", anomaly.dig(:facts, :reason)
        assert_equal "actor_behavior:strict_health_critical:snapshot_invalid", anomaly[:fingerprint]
      end

      private

      def strict_health(**overrides)
        {
          status: "available",
          actor_profiles_eligible: 10,
          actor_behaviors_certified: 10,
          actor_behaviors_missing: 0,
          actor_behaviors_stale: 0,
          handoffs: {
            pending: 0,
            processing: 0,
            failed: 0,
            stale: 0,
            oldest_age_seconds: nil
          },
          automation_missing: false
        }.deep_merge(overrides)
      end
    end
  end
end
