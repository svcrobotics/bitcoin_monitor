# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module ActorBehaviors
  class StrictBatchBuilderTest < ActiveSupport::TestCase
    include ActorBehaviorTestHelper

    test "selects certified profile without snapshot" do
      profile =
        create_certified_actor_profile

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 10)

      assert_includes result.fetch(:profiles), profile
      assert_equal 1, result[:missing_count]
      assert_equal 0, result[:stale_count]
    end

    test "excludes non certified profile" do
      create_certified_actor_profile(dirty: true)

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 10)

      assert_empty result.fetch(:profiles)
    end

    test "excludes profile with current certified snapshot" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 10)

      refute_includes result.fetch(:profiles), profile
    end

    test "selects stale snapshot when actor_profile_id differs" do
      profile =
        create_certified_actor_profile

      other =
        create_certified_actor_profile

      create_current_behavior_snapshot(other)

      snapshot =
        create_current_behavior_snapshot(profile)

      snapshot.update_column(
        :actor_profile_id,
        other.id
      )

      assert_selected_stale(profile)
    end

    test "selects stale snapshot when profile_version differs" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        profile_version: "legacy"
      )

      assert_selected_stale(profile)
    end

    test "selects stale snapshot when profile_height differs" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        profile_height: profile.last_computed_height - 1
      )

      assert_selected_stale(profile)
    end

    test "selects stale snapshot when composition version differs" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        cluster_composition_version:
          profile.cluster_composition_version - 1
      )

      assert_selected_stale(profile)
    end

    test "selects stale snapshot when behavior version differs" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        behavior_version: "strict_v0"
      )

      assert_selected_stale(profile)
    end

    test "selects stale snapshot when status is not certified" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        status: "failed"
      )

      assert_selected_stale(profile)
    end

    test "selects stale snapshot when profile is newer than computed_at" do
      profile =
        create_certified_actor_profile(
          updated_at: 10.minutes.ago
        )

      snapshot =
        create_current_behavior_snapshot(profile)

      snapshot.update!(
        computed_at: 2.hours.ago
      )

      profile.update_column(
        :updated_at,
        Time.current
      )

      assert_selected_stale(profile)
    end

    test "respects strict limit" do
      5.times do
        create_certified_actor_profile
      end

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 3)

      assert_equal 3, result.fetch(:profiles).size
      assert_equal 3, result[:requested_limit]
    end

    test "splits default batch between missing and stale lanes" do
      18.times do
        create_certified_actor_profile
      end

      7.times do
        profile =
          create_certified_actor_profile

        create_current_behavior_snapshot(profile).update!(
          status: "failed"
        )
      end

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 25)

      assert_equal 25, result.fetch(:profiles).size
      assert_equal 18, result[:missing_selected]
      assert_equal 7, result[:stale_selected]
    end

    test "unused missing capacity is recovered by stale lane" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        status: "failed"
      )

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 5)

      assert_equal [profile], result.fetch(:profiles)
      assert_equal 0, result[:missing_selected]
      assert_equal 1, result[:stale_selected]
    end

    test "unused stale capacity is recovered by missing lane" do
      profiles =
        5.times.map do
          create_certified_actor_profile
        end

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 5)

      assert_equal profiles, result.fetch(:profiles)
      assert_equal 5, result[:missing_selected]
      assert_equal 0, result[:stale_selected]
    end

    test "uses stable order" do
      newer =
        create_certified_actor_profile(
          updated_at: 1.minute.ago
        )

      older =
        create_certified_actor_profile(
          updated_at: 1.hour.ago
        )

      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 2)

      assert_equal [older, newer], result.fetch(:profiles)
    end

    test "does not load all actor profiles into memory" do
      3.times do
        create_certified_actor_profile
      end

      actor_profile_selects = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql =
            payload[:sql].to_s

          if sql.match?(/SELECT .*FROM "actor_profiles"/m)
            actor_profile_selects << sql
          end
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorBehaviors::StrictBatchBuilder.call(limit: 2)
      end

      assert actor_profile_selects.any?
      assert(
        actor_profile_selects.all? { |sql| sql.match?(/LIMIT/i) },
        actor_profile_selects.join("\n")
      )
    end

    test "does not use redis cursor" do
      source =
        Rails.root.join(
          "app/services/actor_behaviors/strict_batch_builder.rb"
        ).read

      refute_match(/Redis/, source)
      refute_match(/Sidekiq\.redis/, source)
      refute_match(/cursor/i, source)
    end

    test "does not write while selecting" do
      create_certified_actor_profile

      assert_no_difference -> { ActorBehaviorSnapshot.count } do
        ActorBehaviors::StrictBatchBuilder.call(limit: 5)
      end
    end

    private

    def assert_selected_stale(profile)
      result =
        ActorBehaviors::StrictBatchBuilder.call(limit: 10)

      assert_includes result.fetch(:profiles), profile
      assert_equal 0, result[:missing_count]
      assert_equal 1, result[:stale_count]
    end
  end
end
