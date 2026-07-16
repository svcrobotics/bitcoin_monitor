# frozen_string_literal: true

require "test_helper"

module System
  module Anomalies
    class ActorLabelsRulesTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      test "returns no anomaly for a healthy certified scope" do
        assert_empty ActorLabelsRules.call(
          context: {
            actor_labels_health: strict_health
          }
        )
      end

      test "emits a stable critical anomaly for certified scope divergence" do
        anomaly = ActorLabelsRules.call(
          context: {
            actor_labels_health: strict_health(
              status: "critical",
              actor_profiles: {
                certified: 97,
                expected_certified: 100,
                certified_scope_matches: false
              }
            )
          }
        ).sole.to_h

        assert_equal "actor_labels_strict_integrity_critical", anomaly[:code]
        assert_equal "critical", anomaly[:severity]
        assert_equal "certified_scope_mismatch", anomaly.dig(:facts, :reason)
        assert_equal 97, anomaly.dig(:facts, :certified_profiles)
        assert_equal 100, anomaly.dig(:facts, :expected_certified_profiles)
        assert_equal "actor_labels:strict_integrity_critical:certified_scope_mismatch", anomaly[:fingerprint]
      end

      test "fails closed when the canonical snapshot is absent" do
        anomaly = ActorLabelsRules.call(
          context: {}
        ).sole.to_h

        assert_equal "critical", anomaly[:severity]
        assert_equal "snapshot_missing", anomaly.dig(:facts, :reason)
        assert_equal "actor_labels:strict_integrity_critical:snapshot_missing", anomaly[:fingerprint]
      end

      test "fails closed when the canonical snapshot is invalid" do
        anomaly = ActorLabelsRules.call(
          context: {
            actor_labels_health: strict_health(
              source: "uncertified_actor_labels_projection",
              actor_profiles: {
                certified: "97",
                expected_certified: 100,
                certified_scope_matches: true
              }
            )
          }
        ).sole.to_h

        assert_equal "critical", anomaly[:severity]
        assert_equal "snapshot_invalid", anomaly.dig(:facts, :reason)
        assert_equal "actor_labels:strict_integrity_critical:snapshot_invalid", anomaly[:fingerprint]
      end

      private

      def strict_health(**overrides)
        {
          status: "healthy",
          source: "actor_labels_strict_health_snapshot_v2",
          rule_version: "strict_v2",
          actor_profiles: {
            certified: 100,
            expected_certified: 100,
            certified_scope_matches: true
          }
        }.deep_merge(overrides)
      end
    end
  end
end
