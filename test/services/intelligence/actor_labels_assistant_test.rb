# frozen_string_literal: true

require "test_helper"

module Intelligence
  class ActorLabelsAssistantTest < ActiveSupport::TestCase
    test "explains the active actor behavior dependency" do
      answer =
        Intelligence::ActorLabelsAssistant.call(
          question: "ActorLabels est-il à jour ?",
          context: {
            status: "active",
            pipeline: {
              required_behavior_version: "strict_v2",
              dependency_ready: false,
              source: "actor_labels_from_behavior_strict_v2"
            },
            actor_behaviors: {
              behavior_version: "strict_v2",
              ready: false,
              snapshots_current: 100,
              snapshots_missing: 13_855,
              coverage_percent: 0.72
            },
            actor_labels: {
              total: 0
            }
          }
        )

      assert_includes answer, "raccordé au pipeline strict"
      assert_includes answer, "ActorBehavior strict_v2"
      assert_includes answer, "ne lisent pas directement ActorProfile"
      assert_includes answer, "retail_like reste désactivé"
      assert_includes answer, "Zéro label est un résultat valide"
    end
  end
end
