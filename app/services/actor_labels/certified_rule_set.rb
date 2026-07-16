# frozen_string_literal: true

module ActorLabels
  class CertifiedRuleSet
    RULE_VERSION = StrictRuleSetV2::RULE_VERSION
    SOURCE = StrictRuleSetV2::SOURCE
    ACTIVE_RULES = StrictRuleSetV2::ACTIVE_RULES
    DEFERRED_RULES = StrictRuleSetV2::DEFERRED_RULES

    def self.call(snapshot:)
      signals = snapshot.signals.to_h
      scores = snapshot.scores.to_h
      whale_like = signals["whale_like_candidate_inputs"] == true
      whale_candidate = !whale_like && signals["whale_candidate_inputs"] == true
      results = { "whale_like" => whale_like, "whale_candidate" => whale_candidate }
      labels = results.filter_map do |name, matched|
        next unless matched
        { label: name, confidence: scores["whale_score"].to_i,
          reason: "certified_behavior_signal" }
      end
      { rule_version: RULE_VERSION, active_rules: ACTIVE_RULES,
        deferred_rules: DEFERRED_RULES, rule_results: results, labels: labels }
    end
  end
end
