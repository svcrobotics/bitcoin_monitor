# frozen_string_literal: true

require "test_helper"

module Intelligence
  class ActorBehaviorsAssistantTest < ActiveSupport::TestCase
    test "presents only certified ActorBehavior context" do
      context = {
        status: "available",
        actor_profiles_eligible: 200,
        actor_behaviors_certified: 150,
        actor_behaviors_missing: 40,
        actor_behaviors_stale: 10,
        coverage: 0.75
      }

      answer = ActorBehaviorsAssistant.call(
        question: "Quel est l’état ActorBehavior ?",
        context: context
      )

      assert_includes answer, "État certifié ActorBehavior disponible"
      assert_includes answer, "150 snapshot(s) sur 200 profil(s)"
      assert_includes answer, "75.00 %"
      assert_includes answer, "40 manquant(s) et 10 périmé(s)"
      assert_not_includes answer, "ActorLabel"
      assert_not_includes answer, "exchange"
    end

    test "is deterministic for the same certified context" do
      context = {
        status: "available",
        actor_profiles_eligible: 1,
        actor_behaviors_certified: 1,
        actor_behaviors_missing: 0,
        actor_behaviors_stale: 0,
        coverage: 1.0
      }

      first = ActorBehaviorsAssistant.call(question: "première forme", context:)
      second = ActorBehaviorsAssistant.call(question: "seconde forme", context:)

      assert_equal first, second
    end

    test "reports certified data as unavailable when context is absent" do
      answer = ActorBehaviorsAssistant.call(question: "État ?", context: nil)

      assert_equal \
        "Aucune donnée certifiée ActorBehavior n’est disponible.",
        answer
    end
  end
end
