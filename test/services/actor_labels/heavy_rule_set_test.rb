# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class HeavyRuleSetTest <
    ActiveSupport::TestCase

    Snapshot =
      Struct.new(
        :id,
        :cluster_id,
        :downstream_cluster_id,
        :actor_profile_id,
        :analysis_kind,
        :heavy_version,
        :status,
        :window_from_height,
        :window_to_height,
        :evidence_fingerprint,
        :computed_at,
        :signals,
        :scores,
        :evidence,
        keyword_init: true
      )

    test "publishes infrastructure candidate from certified heavy evidence" do
      result =
        HeavyRuleSet.call(
          snapshot:
            build_snapshot
        )

      assert_equal(
        true,
        result[:eligible]
      )

      assert_equal(
        [
          "exchange_infrastructure_candidate"
        ],
        result[:labels].map do |label|
          label[:label]
        end
      )

      assert_equal(
        90,
        result[:labels]
          .first
          .fetch(
            :confidence
          )
      )

      assert_equal(
        HeavyRuleSet::SOURCE,
        result[:source]
      )
    end

    test "does not publish when candidate signal is false" do
      snapshot =
        build_snapshot

      snapshot.signals =
        snapshot
          .signals
          .merge(
            "exchange_infrastructure_candidate" =>
              false
          )

      result =
        HeavyRuleSet.call(
          snapshot:
            snapshot
        )

      assert_equal(
        true,
        result[:eligible]
      )

      assert_empty(
        result[:labels]
      )
    end

    test "does not publish below mandatory sweep concentration" do
      snapshot =
        build_snapshot

      snapshot.evidence[
        "sweep"
      ][
        "top_destination_share_percent"
      ] =
        "43.41"

      result =
        HeavyRuleSet.call(
          snapshot:
            snapshot
        )

      assert_equal(
        true,
        result[:eligible]
      )

      assert_empty(
        result[:labels]
      )
    end

    test "rejects an incompatible heavy version" do
      snapshot =
        build_snapshot

      snapshot.heavy_version =
        "old_version"

      result =
        HeavyRuleSet.call(
          snapshot:
            snapshot
        )

      assert_equal(
        false,
        result[:eligible]
      )

      assert_equal(
        :heavy_version_mismatch,
        result[:reason]
      )
    end

    test "rejects a service infrastructure snapshot" do
      snapshot =
        build_snapshot

      snapshot.analysis_kind =
        "service_infrastructure"

      result =
        HeavyRuleSet.call(
          snapshot:
            snapshot
        )

      assert_equal(
        false,
        result[:eligible]
      )

      assert_equal(
        :analysis_kind_mismatch,
        result[:reason]
      )

      assert_empty(
        result[:labels]
      )
    end

    private

    def build_snapshot
      Snapshot.new(
        id: 3,
        cluster_id: 21_885,
        downstream_cluster_id: 932_417,
        actor_profile_id: 51_260,

        analysis_kind:
          "exchange_infrastructure",

        heavy_version:
          ActorBehaviors::Heavy::
            BuildFromEvidence::
            HEAVY_VERSION,

        status:
          "certified",

        window_from_height:
          953_901,

        window_to_height:
          956_900,

        evidence_fingerprint:
          "abc123",

        computed_at:
          Time.current,

        signals: {
          "collection_consolidation_observed" =>
            true,

          "recurrent_sweep_to_active_wallet" =>
            true,

          "broad_batch_distribution" =>
            true,

          "exchange_infrastructure_candidate" =>
            true,

          "exchange_identity_verified" =>
            false
        },

        scores: {
          "deposit_collection_score" =>
            100,

          "sweep_relation_score" =>
            100,

          "downstream_distribution_score" =>
            100,

          "exchange_infrastructure_score" =>
            100,

          "classification_confidence" =>
            90
        },

        evidence: {
          "sweep" => {
            "top_destination_share_percent" =>
              "100.0"
          },

          "score_evidence" => {
            "reasons" => [
              "deposit_collection_pattern_observed",
              "recurrent_sweep_to_active_wallet_observed",
              "broad_batch_distribution_observed",
              "identity_not_verified_on_chain"
            ]
          },

          "provenance" => {
            "builder_version" =>
              "actor_behavior_heavy_build_v1"
          }
        }
      )
    end
  end
end
