# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class StrictRuleSetTest < ActiveSupport::TestCase
    test "creates every supported behavior label" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot(
            signals: base_signals.merge(
              "whale_like_candidate_inputs" => true,
              "exchange_like_candidate_inputs" => true,
              "service_like_candidate_inputs" => true,
              "etf_candidate_inputs" => true
            ),
            scores: {
              "whale_score" => 90,
              "exchange_score" => 80,
              "service_score" => 75,
              "etf_score" => 70
            }
          )
        )

      assert_equal true, result[:eligible]

      assert_equal(
        %w[
          whale_like
          exchange_like
          service_like
          etf_candidate
        ],
        result[:labels].map { |label| label[:label] }
      )
    end

    test "prefers whale like over whale candidate" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot(
            signals: base_signals.merge(
              "whale_like_candidate_inputs" => true,
              "whale_candidate_inputs" => true
            ),
            scores: base_scores.merge(
              "whale_score" => 90
            )
          )
        )

      assert_equal(
        ["whale_like"],
        result[:labels].map { |label| label[:label] }
      )
    end

    test "creates whale candidate independently" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot(
            signals: base_signals.merge(
              "whale_candidate_inputs" => true
            ),
            scores: base_scores.merge(
              "whale_score" => 70
            )
          )
        )

      assert_equal(
        ["whale_candidate"],
        result[:labels].map { |label| label[:label] }
      )
    end

    test "does not create etf like from behavior" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot(
            signals: base_signals.merge(
              "etf_candidate_inputs" => true
            ),
            scores: base_scores.merge(
              "etf_score" => 80
            )
          )
        )

      names =
        result[:labels].map { |label| label[:label] }

      assert_includes names, "etf_candidate"
      refute_includes names, "etf_like"
    end

    test "does not create retail while rule is disabled" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot(
            signals: base_signals.merge(
              "retail_like_candidate_inputs" => true
            )
          )
        )

      assert_empty result[:labels]
    end

    test "creates no label when all signals are false" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot
        )

      assert_equal true, result[:eligible]
      assert_empty result[:labels]
    end

    test "rejects another behavior version" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot(
            behavior_version: "strict_v1"
          )
        )

      assert_equal false, result[:eligible]
      assert_equal :behavior_version_mismatch, result[:reason]
    end

    test "rejects snapshots without the complete signal contract" do
      result =
        ActorLabels::StrictRuleSet.call(
          snapshot: build_snapshot(
            signals: {
              "whale_like_candidate_inputs" => false
            }
          )
        )

      assert_equal false, result[:eligible]
      assert_equal :required_signals_missing, result[:reason]
    end

    private

    def base_signals
      {
        "holder_size" => "regular",
        "large_holder" => false,
        "very_large_holder" => false,
        "whale_like_candidate_inputs" => false,
        "whale_candidate_inputs" => false,
        "exchange_like_candidate_inputs" => false,
        "service_like_candidate_inputs" => false,
        "etf_candidate_inputs" => false,
        "retail_like_candidate_inputs" => false
      }
    end

    def base_scores
      {
        "whale_score" => 5,
        "exchange_score" => 0,
        "service_score" => 0,
        "etf_score" => 0
      }
    end

    def build_snapshot(
      status: "certified",
      behavior_version: "strict_v2",
      signals: nil,
      scores: nil
    )
      ActorBehaviorSnapshot.new(
        cluster_id: 12,
        actor_profile_id: 34,
        profile_version: "strict_v4_core_facts",
        profile_height: 956_197,
        cluster_composition_version: 2,
        profile_fingerprint: "fingerprint-v2",
        behavior_version: behavior_version,
        status: status,
        signals: signals || base_signals,
        scores: scores || base_scores,
        evidence: {
          "behavior_version" => behavior_version
        },
        computed_at: Time.current
      )
    end
  end
end
