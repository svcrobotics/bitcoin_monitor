# frozen_string_literal: true

require "test_helper"

module Intelligence
  class ActorBehaviorsAssistantTest < ActiveSupport::TestCase
    test "describes a shadow build using certified facts" do
      context = {
        status: "shadow_building",
        operational: {
          actor_profiles_certified: 13_632,
          snapshots_current: 100,
          snapshots_missing: 13_532,
          snapshots_stale: 0,
          coverage_percent: 0.73,
          last_run_status: "completed",
          last_run_duration_ms: 5_244
        }
      }

      answer =
        Intelligence::ActorBehaviorsAssistant.call(
          question: "État de ActorBehavior",
          context: context
        )

      assert_includes answer, "mode shadow"
      assert_includes answer, "100 snapshot(s)"
      assert_includes answer, "13632 profil(s)"
      assert_includes answer, "0.73 %"
      assert_includes answer, "13532 manquant(s)"
      assert_includes answer, "completed en 5244 ms"
      assert_includes answer, "aucun ActorLabel"
    end

    test "reports shadow ready without claiming labels exist" do
      context = {
        status: "shadow_ready",
        operational: {
          actor_profiles_certified: 1,
          snapshots_current: 1,
          snapshots_missing: 0,
          snapshots_stale: 0,
          coverage_percent: 100
        }
      }

      answer =
        Intelligence::ActorBehaviorsAssistant.call(
          question: "ActorBehavior est-il prêt ?",
          context: context
        )

      assert_includes answer, "prêt en mode shadow"
      assert_includes answer, "aucun ActorLabel"
    end
  end
end
