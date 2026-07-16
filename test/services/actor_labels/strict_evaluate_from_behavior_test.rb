# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class StrictEvaluateFromBehaviorTest < ActiveSupport::TestCase
    def setup
      @cluster = Cluster.create!(composition_version: 1)
      @profile = ActorProfile.create!(cluster: @cluster)
      @snapshot = ActorBehaviorSnapshot.create!(cluster: @cluster, actor_profile: @profile,
        profile_version: "strict_v3_core", profile_height: 10,
        cluster_composition_version: 1, profile_fingerprint: "fp",
        behavior_version: "strict_v2", status: "certified", source_hash: "hash",
        certification_scope: "strict", certified_at: Time.current,
        computed_at: Time.current, signals: { "whale_like_candidate_inputs" => true,
          "whale_candidate_inputs" => true }, scores: { "whale_score" => 85 })
      HandoffRegistration.call(snapshot: @snapshot)
      @args = { cluster_id: @cluster.id, cluster_composition_version: 1,
        profile_version: "strict_v3_core", source_height: 10, source_hash: "hash",
        behavior_version: "strict_v2", behavior_snapshot_id: @snapshot.id,
        rule_version: CertifiedRuleSet::RULE_VERSION }
    end

    test "evaluates active rules and persists positive and negative proof" do
      result = StrictEvaluateFromBehavior.call(**@args)
      assert_equal "evaluated", result[:status]
      assert_equal({ "whale_like" => true, "whale_candidate" => false },
        ActorLabelEvaluation.find(result[:evaluation_id]).rule_results)
      assert_equal %w[whale_like], ActorLabel.where(source: CertifiedRuleSet::SOURCE).pluck(:label)
      assert_empty ActorLabel.where(label: CertifiedRuleSet::DEFERRED_RULES)
      assert JSON.generate(result)
    end

    test "replay is current and a negative evaluation removes only strict labels" do
      StrictEvaluateFromBehavior.call(**@args)
      manual = ActorLabel.create!(cluster: @cluster, label: "etf_like", source: "manual")
      @snapshot.update_columns(signals: { "whale_like_candidate_inputs" => false,
        "whale_candidate_inputs" => false })
      ActorLabelEvaluation.delete_all
      result = StrictEvaluateFromBehavior.call(**@args)
      again = StrictEvaluateFromBehavior.call(**@args)
      assert_equal "evaluated", result[:status]
      assert_equal "already_current", again[:status]
      assert_empty ActorLabel.where(source: CertifiedRuleSet::SOURCE)
      assert manual.reload
      assert_equal({ "whale_like" => false, "whale_candidate" => false }, result[:rule_results])
    end

    test "refuses unknown rule and divergent snapshot" do
      unknown = StrictEvaluateFromBehavior.call(**@args.merge(rule_version: "future"))
      divergent = StrictEvaluateFromBehavior.call(**@args.merge(source_hash: "other"))
      assert_equal "refused", unknown[:status]
      assert_equal "unknown_rule_version", unknown[:reason]
      assert_equal "refused", divergent[:status]
      assert_equal "snapshot_missing", divergent[:reason]
      assert_equal 0, ActorLabelEvaluation.count
    end
  end
end
