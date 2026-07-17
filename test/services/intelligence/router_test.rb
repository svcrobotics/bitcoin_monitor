# frozen_string_literal: true

require "test_helper"

module Intelligence
  class RouterTest < ActiveSupport::TestCase
    test "routes actor behavior question to local health context" do
      route =
        Intelligence::Router.call(
          "Quel est l’état de ActorBehavior ?"
        )

      assert_equal :actor_behaviors_health, route[:intent]
      assert_equal :local, route[:provider]
      assert_equal :actor_behaviors_health, route[:source]
      assert_equal(
        "actor_behaviors_health",
        route.dig(:context, :module)
      )
    end

    test "routes french actor behavior wording" do
      route =
        Intelligence::Router.call(
          "État des comportements acteurs"
        )

      assert_equal :actor_behaviors_health, route[:intent]
    end

    test "does not confuse actor behavior with actor labels" do
      route =
        Intelligence::Router.call(
          "Actor Behavior est-il à jour ?"
        )

      refute_equal :actor_labels_health, route[:intent]
      refute_equal :actor_profiles_health, route[:intent]
    end
  end
end
