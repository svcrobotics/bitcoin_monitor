# frozen_string_literal: true

require "test_helper"

module System
  module Anomalies
    class ActorProfileRulesTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      test "returns no anomaly for a healthy strict snapshot" do
        assert_empty ActorProfileRules.call(
          context: {
            actor_profile_health: strict_health
          }
        )
      end

      test "emits a stable critical anomaly for failed strict handoffs" do
        anomaly = ActorProfileRules.call(
          context: {
            actor_profile_health: strict_health(
              status: "warning",
              handoffs: {
                failed: 2,
                stale: 0,
                oldest_age_seconds: 180
              }
            )
          }
        ).sole.to_h

        assert_equal "actor_profile_strict_health_critical", anomaly[:code]
        assert_equal "critical", anomaly[:severity]
        assert_equal "failed_handoffs", anomaly.dig(:facts, :reason)
        assert_equal 2, anomaly.dig(:facts, :failed_handoffs)
        assert_equal 180, anomaly.dig(:facts, :oldest_handoff_age_seconds)
        assert_equal "actor_profile:strict_health_critical:failed_handoffs", anomaly[:fingerprint]
      end

      test "fails closed when the canonical snapshot is unavailable" do
        anomaly = ActorProfileRules.call(
          context: {
            actor_profile_health: strict_health(
              available: false,
              status: "unavailable",
              handoffs: {
                failed: nil,
                stale: nil
              }
            )
          }
        ).sole.to_h

        assert_equal "critical", anomaly[:severity]
        assert_equal "snapshot_unavailable", anomaly.dig(:facts, :reason)
        assert_equal "actor_profile:strict_health_critical:snapshot_unavailable", anomaly[:fingerprint]
      end

      test "fails closed when snapshot identity is invalid" do
        anomaly = ActorProfileRules.call(
          context: {
            actor_profile_health: {
              module: "actor_profiles_strict",
              source: "unknown_projection",
              available: true,
              status: "healthy",
              handoffs: {
                failed: 0,
                stale: 0
              }
            }
          }
        ).sole.to_h

        assert_equal "critical", anomaly[:severity]
        assert_equal "snapshot_invalid", anomaly.dig(:facts, :reason)
        assert_equal "actor_profile:strict_health_critical:snapshot_invalid", anomaly[:fingerprint]
      end

      private

      def strict_health(**overrides)
        {
          module: "actor_profiles_strict",
          source: "canonical_postgresql_chain",
          available: true,
          status: "healthy",
          handoffs: {
            failed: 0,
            stale: 0,
            oldest_age_seconds: nil
          }
        }.deep_merge(overrides)
      end
    end
  end
end
