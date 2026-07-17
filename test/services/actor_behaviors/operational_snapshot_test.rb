# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module ActorBehaviors
  class OperationalSnapshotTest < ActiveSupport::TestCase
    include ActorBehaviorTestHelper

    test "reports no certified profile" do
      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal "shadow", snapshot[:mode]
      assert_equal 0, snapshot[:actor_profiles_certified]
      assert_equal 0, snapshot[:snapshots_current]
      assert_equal 0, snapshot[:snapshots_missing]
      assert_equal 0.0, snapshot[:coverage_ratio]
      assert_equal 0.0, snapshot[:coverage_percent]
      assert_nil snapshot[:checkpoint_lag]
      assert snapshot[:coverage_invariant_ok]
    end

    test "reports certified profiles without snapshots as missing" do
      create_certified_actor_profile

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:actor_profiles_certified]
      assert_equal 1, snapshot[:snapshots_missing]
      assert_equal 0, snapshot[:snapshots_current]
      assert_equal 0, snapshot[:snapshots_stale]
      assert_invariant(snapshot)
    end

    test "reports partial coverage" do
      current =
        create_certified_actor_profile

      create_certified_actor_profile
      create_current_behavior_snapshot(current)

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 2, snapshot[:actor_profiles_certified]
      assert_equal 1, snapshot[:snapshots_current]
      assert_equal 1, snapshot[:snapshots_missing]
      assert_equal 0.5, snapshot[:coverage_ratio]
      assert_equal 50.0, snapshot[:coverage_percent]
      assert_invariant(snapshot)
    end

    test "reports complete coverage" do
      profiles =
        2.times.map do
          create_certified_actor_profile
        end

      profiles.each do |profile|
        create_current_behavior_snapshot(profile)
      end

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 2, snapshot[:actor_profiles_certified]
      assert_equal 2, snapshot[:snapshots_current]
      assert_equal 0, snapshot[:snapshots_missing]
      assert_equal 0, snapshot[:snapshots_stale]
      assert_equal 1.0, snapshot[:coverage_ratio]
      assert_equal 100.0, snapshot[:coverage_percent]
      assert_invariant(snapshot)
    end

    test "recognizes current snapshot" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:snapshots_current]
      assert_equal 0, snapshot[:snapshots_stale]
    end

    test "recognizes stale behavior version" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        behavior_version: "strict_v0"
      )

      assert_stale_snapshot
    end

    test "recognizes stale profile height" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        profile_height: profile.last_computed_height - 1
      )

      assert_stale_snapshot
    end

    test "recognizes stale profile version" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        profile_version: "legacy"
      )

      assert_stale_snapshot
    end

    test "recognizes stale composition version" do
      profile =
        create_certified_actor_profile(
          profile_composition_version: 3,
          cluster_composition_version: 3
        )

      create_current_behavior_snapshot(profile).update!(
        cluster_composition_version: 2
      )

      assert_stale_snapshot
    end

    test "recognizes incoherent actor_profile_id" do
      profile =
        create_certified_actor_profile

      other =
        create_certified_actor_profile

      create_current_behavior_snapshot(other)

      create_current_behavior_snapshot(profile).update_column(
        :actor_profile_id,
        other.id
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 2, snapshot[:actor_profiles_certified]
      assert_equal 1, snapshot[:snapshots_current]
      assert_equal 1, snapshot[:snapshots_stale]
      assert_invariant(snapshot)
    end

    test "recognizes non certified status" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        status: "failed"
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:snapshots_non_certified_status]
      assert_equal 1, snapshot[:snapshots_stale]
      assert_equal({ "failed" => 1 }, snapshot[:snapshot_statuses])
      assert_invariant(snapshot)
    end

    test "calculates missing stale and current together" do
      current =
        create_certified_actor_profile

      stale =
        create_certified_actor_profile

      create_certified_actor_profile

      create_current_behavior_snapshot(current)
      create_current_behavior_snapshot(stale).update!(
        behavior_version: "strict_v0"
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:snapshots_current]
      assert_equal 1, snapshot[:snapshots_missing]
      assert_equal 1, snapshot[:snapshots_stale]
      assert_invariant(snapshot)
    end

    test "calculates coverage ratio and percent" do
      current =
        create_certified_actor_profile

      3.times do
        create_certified_actor_profile
      end

      create_current_behavior_snapshot(current)

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 0.25, snapshot[:coverage_ratio]
      assert_equal 25.0, snapshot[:coverage_percent]
    end

    test "handles division by zero" do
      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 0.0, snapshot[:coverage_ratio]
      assert_equal 0.0, snapshot[:coverage_percent]
    end

    test "calculates checkpoint lag" do
      current =
        create_certified_actor_profile(
          last_computed_height: 100
        )

      stale =
        create_certified_actor_profile(
          last_computed_height: 120
        )

      create_current_behavior_snapshot(current)
      create_current_behavior_snapshot(stale).update!(
        behavior_version: "strict_v0"
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 120, snapshot[:actor_profile_max_height]
      assert_equal 100, snapshot[:behavior_snapshot_max_height]
      assert_equal 20, snapshot[:checkpoint_lag]
    end

    test "reports no existing snapshot" do
      create_certified_actor_profile

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 0, snapshot[:snapshots_total]
      assert_nil snapshot[:latest_computed_at]
      assert_nil snapshot[:oldest_current_computed_at]
    end

    test "reports behavior version distribution" do
      current =
        create_certified_actor_profile

      stale =
        create_certified_actor_profile

      create_current_behavior_snapshot(current)
      create_current_behavior_snapshot(stale).update!(
        behavior_version: "strict_v0"
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:behavior_versions]["strict_v2"]
      assert_equal 1, snapshot[:behavior_versions]["strict_v0"]
    end

    test "reports snapshot status distribution" do
      current =
        create_certified_actor_profile

      failed =
        create_certified_actor_profile

      create_current_behavior_snapshot(current)
      create_current_behavior_snapshot(failed).update!(
        status: "failed"
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:snapshot_statuses]["certified"]
      assert_equal 1, snapshot[:snapshot_statuses]["failed"]
    end

    test "reports no run" do
      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 0, snapshot[:runs_total]
      assert_nil snapshot[:last_run_id]
      assert_equal({}, snapshot[:last_run_counts])
      assert_nil snapshot[:last_successful_run_at]
      assert_equal 0, snapshot[:running_runs]
      assert_equal 0, snapshot[:stale_running_runs]
    end

    test "reports last completed run" do
      run =
        create_behavior_run(
          status: "completed",
          selected: 2,
          created_count: 2,
          reasons: { "ok" => 2 }
        )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:runs_total]
      assert_equal run.id, snapshot[:last_run_id]
      assert_equal "completed", snapshot[:last_run_status]
      assert_equal "test", snapshot[:last_run_trigger]
      assert_equal run.started_at, snapshot[:last_run_started_at]
      assert_equal run.finished_at, snapshot[:last_run_finished_at]
      assert_equal 10, snapshot[:last_run_duration_ms]
      assert_equal(
        {
          selected: 2,
          missing_selected: 0,
          stale_selected: 0,
          created: 2,
          updated: 0,
          unchanged: 0,
          deferred: 0,
          failed: 0
        },
        snapshot[:last_run_counts]
      )
      assert_equal({ "ok" => 2 }, snapshot[:last_run_reasons])
      assert_equal run.finished_at, snapshot[:last_successful_run_at]
    end

    test "reports last completed_with_errors run" do
      run =
        create_behavior_run(
          status: "completed_with_errors",
          selected: 1,
          failed_count: 1,
          reasons: { "unexpected_error" => 1 }
        )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal run.id, snapshot[:last_run_id]
      assert_equal "completed_with_errors", snapshot[:last_run_status]
      assert_equal({ "unexpected_error" => 1 }, snapshot[:last_run_reasons])
      assert_nil snapshot[:last_successful_run_at]
    end

    test "reports last failed run" do
      run =
        create_behavior_run(
          status: "failed",
          error_code: "RuntimeError",
          error_message: "RuntimeError: boom"
        )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal run.id, snapshot[:last_run_id]
      assert_equal "failed", snapshot[:last_run_status]
    end

    test "reports running and stale running runs" do
      create_behavior_run(status: "running")
      create_behavior_run(
        status: "running",
        started_at:
          ActorBehaviorRun::STALE_RUNNING_AFTER.ago -
            1.minute
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 2, snapshot[:running_runs]
      assert_equal 1, snapshot[:stale_running_runs]
    end

    test "actor profile max height uses certified scope" do
      create_certified_actor_profile(
        last_computed_height: 150
      )

      create_certified_actor_profile(
        dirty: true,
        last_computed_height: 999
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 150, snapshot[:actor_profile_max_height]
    end

    test "does not load all actor profiles into memory" do
      3.times do
        create_certified_actor_profile
      end

      actor_profile_loads = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql =
            payload[:sql].to_s

          if sql.match?(/SELECT\s+"actor_profiles"\.\*/i)
            actor_profile_loads << sql
          end
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorBehaviors::OperationalSnapshot.call
      end

      assert_empty actor_profile_loads
    end

    test "does not write data" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      assert_no_difference -> { ActorBehaviorSnapshot.count } do
        assert_no_difference -> { ActorProfile.count } do
          assert_no_difference -> { ActorLabel.count } do
            assert_no_difference -> { ActorBehaviorRun.count } do
              ActorBehaviors::OperationalSnapshot.call
            end
          end
        end
      end
    end

    test "uses definitions coherent with strict batch builder" do
      current =
        create_certified_actor_profile

      stale =
        create_certified_actor_profile

      missing =
        create_certified_actor_profile

      create_current_behavior_snapshot(current)
      create_current_behavior_snapshot(stale).update!(
        profile_height: stale.last_computed_height - 1
      )

      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      builder =
        ActorBehaviors::StrictBatchBuilder.call(limit: 10)

      assert_equal 1, snapshot[:snapshots_missing]
      assert_equal 1, snapshot[:snapshots_stale]
      assert_equal(
        [missing.id, stale.id].sort,
        builder.fetch(:profiles).map(&:id).sort
      )
    end

    private

    def assert_stale_snapshot
      snapshot =
        ActorBehaviors::OperationalSnapshot.call

      assert_equal 1, snapshot[:actor_profiles_certified]
      assert_equal 0, snapshot[:snapshots_current]
      assert_equal 0, snapshot[:snapshots_missing]
      assert_equal 1, snapshot[:snapshots_stale]
      assert_invariant(snapshot)
    end

    def assert_invariant(snapshot)
      assert snapshot[:coverage_invariant_ok]

      assert_equal(
        snapshot[:actor_profiles_certified],
        snapshot[:snapshots_current] +
          snapshot[:snapshots_missing] +
          snapshot[:snapshots_stale]
      )
    end

    def create_behavior_run(**attributes)
      status =
        attributes.fetch(:status, "completed")

      defaults = {
        behavior_version:
          ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,
        mode: "shadow",
        trigger: "test",
        requested_limit: 25,
        status: status,
        started_at: Time.current,
        finished_at:
          status == "running" ? nil : Time.current,
        duration_ms:
          status == "running" ? nil : 10,
        selected: 0,
        missing_selected: 0,
        stale_selected: 0,
        created_count: 0,
        updated_count: 0,
        unchanged_count: 0,
        deferred_count: 0,
        failed_count: 0,
        reasons: {}
      }

      ActorBehaviorRun.create!(
        defaults.merge(attributes)
      )
    end
  end
end
