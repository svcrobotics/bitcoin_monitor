# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module ActorBehaviors
  class StrictHealthSnapshotTest < ActiveSupport::TestCase
    include ActorBehaviorTestHelper

    test "returns shadow_empty without snapshots" do
      create_certified_actor_profile

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call

      assert_equal "shadow_empty", snapshot[:status]
      assert_equal "shadow", snapshot[:phase]
      assert_includes snapshot[:reasons], "no_behavior_snapshots"
    end

    test "returns shadow_building with partial coverage" do
      current =
        create_certified_actor_profile

      create_certified_actor_profile
      create_current_behavior_snapshot(current)

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call

      assert_equal "shadow_building", snapshot[:status]
      assert_includes snapshot[:reasons], "missing_behavior_snapshots"
    end

    test "returns shadow_building with stale snapshot" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        profile_height: profile.last_computed_height - 1
      )

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call

      assert_equal "shadow_building", snapshot[:status]
      refute_includes snapshot[:reasons], "no_behavior_snapshots"
      assert_includes snapshot[:reasons], "stale_behavior_snapshots"
    end

    test "returns shadow_ready with complete coverage" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call

      assert_equal "shadow_ready", snapshot[:status]
      assert_empty snapshot[:reasons]
    end

    test "ready false for shadow_empty" do
      create_certified_actor_profile

      refute ActorBehaviors::StrictHealthSnapshot.call[:ready]
    end

    test "ready false for shadow_building" do
      current =
        create_certified_actor_profile

      create_certified_actor_profile
      create_current_behavior_snapshot(current)

      refute ActorBehaviors::StrictHealthSnapshot.call[:ready]
    end

    test "ready true for shadow_ready" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      assert ActorBehaviors::StrictHealthSnapshot.call[:ready]
    end

    test "reports no certified actor profiles" do
      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call

      assert_equal "shadow_empty", snapshot[:status]
      assert_includes(
        snapshot[:reasons],
        "no_certified_actor_profiles"
      )
    end

    test "reports stale behavior snapshots reason" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        profile_height: profile.last_computed_height - 1
      )

      assert_includes(
        ActorBehaviors::StrictHealthSnapshot.call[:reasons],
        "stale_behavior_snapshots"
      )
    end

    test "reports non certified snapshot statuses" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        status: "failed"
      )

      assert_includes(
        ActorBehaviors::StrictHealthSnapshot.call[:reasons],
        "non_certified_snapshot_statuses"
      )
    end

    test "reports behavior version mismatch" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        behavior_version: "strict_v0"
      )

      assert_includes(
        ActorBehaviors::StrictHealthSnapshot.call[:reasons],
        "behavior_version_mismatch"
      )
    end

    test "does not expose active statuses in shadow mode" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      status =
        ActorBehaviors::StrictHealthSnapshot.call[:status]

      refute_match(/\Aactive_/, status)
    end

    test "low coverage does not produce critical status" do
      current =
        create_certified_actor_profile

      9.times do
        create_certified_actor_profile
      end

      create_current_behavior_snapshot(current)

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call

      assert_equal "shadow_building", snapshot[:status]
      refute_equal "critical", snapshot[:status]
    end

    test "does not report checkpoint lag while missing snapshots remain" do
      current =
        create_certified_actor_profile(
          last_computed_height: 100
        )

      create_certified_actor_profile(
        last_computed_height: 120
      )

      create_current_behavior_snapshot(current)

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call

      assert_equal 20, snapshot[:operational][:checkpoint_lag]
      assert_includes snapshot[:reasons], "missing_behavior_snapshots"
      refute_includes snapshot[:reasons], "behavior_checkpoint_lag"
    end

    test "can report checkpoint lag once coverage is otherwise complete" do
      operational =
        operational_hash(
          actor_profiles_certified: 1,
          snapshots_current: 1,
          snapshots_missing: 0,
          snapshots_stale: 0,
          checkpoint_lag: 5
        )

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call(
          operational: operational
        )

      assert_equal "shadow_ready", snapshot[:status]
      assert_includes snapshot[:reasons], "behavior_checkpoint_lag"
    end

    test "builds operational snapshot only once" do
      calls = 0

      with_stubbed(
        ActorBehaviors::OperationalSnapshot,
        :call,
        lambda do
          calls += 1
          operational_hash
        end
      ) do
        ActorBehaviors::StrictHealthSnapshot.call
      end

      assert_equal 1, calls
    end

    test "accepts injected operational snapshot" do
      operational =
        operational_hash

      snapshot =
        ActorBehaviors::StrictHealthSnapshot.call(
          operational: operational
        )

      assert_same operational, snapshot[:operational]
    end

    test "does not add cache dependencies" do
      source =
        Rails.root.join(
          "app/services/actor_behaviors/strict_health_snapshot.rb"
        ).read

      refute_match(/Redis/, source)
      refute_match(/Sidekiq/, source)
      refute_match(/Rails\.cache/, source)
    end

    test "does not write data" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      assert_no_difference -> { ActorBehaviorSnapshot.count } do
        assert_no_difference -> { ActorProfile.count } do
          assert_no_difference -> { ActorLabel.count } do
            ActorBehaviors::StrictHealthSnapshot.call
          end
        end
      end
    end

    private

    def operational_hash(**overrides)
      {
        actor_profiles_certified: 1,
        snapshots_current: 1,
        snapshots_missing: 0,
        snapshots_stale: 0,
        snapshots_non_certified_status: 0,
        checkpoint_lag: 0,
        behavior_version:
          ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,
        behavior_versions: {
          ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION => 1
        }
      }.merge(overrides)
    end

    def with_stubbed(object, method_name, replacement)
      singleton =
        class << object
          self
        end

      original =
        :"#{method_name}_without_actor_behavior_health_test"

      singleton.alias_method original, method_name

      singleton.define_method(method_name) do |*args, **kwargs, &block|
        if replacement.respond_to?(:call)
          replacement.call(*args, **kwargs, &block)
        else
          replacement
        end
      end

      yield
    ensure
      singleton.alias_method method_name, original
      singleton.remove_method original
    end
  end
end
