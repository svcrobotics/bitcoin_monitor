# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module Intelligence
  class ContextBuilderTest < ActiveSupport::TestCase
    include ActorBehaviorTestHelper

    test "builds actor behavior health context from strict snapshot" do
      profile =
        create_certified_actor_profile(
          last_computed_height: 120
        )

      create_current_behavior_snapshot(profile)

      context =
        Intelligence::ContextBuilder.actor_behaviors_health

      assert_equal "shadow_ready", context[:status]
      assert_equal "shadow", context[:phase]
      assert_equal true, context[:ready]

      assert_equal(
        "actor_behaviors_health",
        context[:module]
      )

      assert_equal(
        "actor_behaviors_strict_health_snapshot",
        context[:source]
      )

      assert_equal(
        1,
        context.dig(:operational, :snapshots_current)
      )

      assert_equal(
        0,
        context.dig(:operational, :snapshots_missing)
      )
    end
  end
end
