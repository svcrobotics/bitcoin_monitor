# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class StrictHealthSnapshotTest < ActiveSupport::TestCase
    test "reports actor labels as connected to actor behavior" do
      snapshot =
        ActorLabels::StrictHealthSnapshot.call(
          behavior_snapshot: behavior_snapshot,
          control_snapshot: control_snapshot
        )

      assert_equal "active", snapshot[:status]
      assert_equal true, snapshot[:ready]
      assert_empty snapshot[:reasons]

      assert_equal(
        "actor_behaviors",
        snapshot.dig(:pipeline, :dependency)
      )

      assert_equal(
        "strict_v2",
        snapshot.dig(:pipeline, :required_behavior_version)
      )

      assert_equal(
        true,
        snapshot.dig(:pipeline, :automation_enabled)
      )

      assert_equal(
        true,
        snapshot.dig(
          :pipeline,
          :automatic_write_enabled
        )
      )

      assert_equal(
        true,
        snapshot.dig(
          :pipeline,
          :worker_write_observed
        )
      )

      assert_equal(
        true,
        snapshot.dig(
          :pipeline,
          :worker_write_enabled
        )
      )

      assert_equal(
        true,
        snapshot.dig(:pipeline, :zero_labels_is_valid)
      )

      assert_equal(
        100,
        snapshot.dig(:actor_behaviors, :snapshots_current)
      )

      assert_equal(
        13_855,
        snapshot.dig(:actor_behaviors, :snapshots_missing)
      )

      assert_equal(
        0,
        snapshot.dig(:actor_labels, :total)
      )

      assert_equal(
        12,
        snapshot.dig(:actor_labels, :pending_for_labels)
      )
    end

    test "does not use actor profiles or legacy label pipelines" do
      source =
        Rails.root.join(
          "app/services/actor_labels/strict_health_snapshot.rb"
        ).read

      refute_match(/ActorProfiles::/, source)
      refute_match(/StrictRuleSetV2/, source)
      refute_match(/RefreshFromActorProfile/, source)
      refute_match(/actor_labels_strict_v3_core/, source)
    end

    private

    def behavior_snapshot
      {
        status: "shadow_building",
        phase: "shadow",
        ready: false,
        reasons: [
          "behavior_backfill_in_progress",
          "missing_behavior_snapshots"
        ],
        operational: {
          behavior_version: "strict_v2",
          actor_profiles_certified: 13_955,
          snapshots_total: 100,
          snapshots_current: 100,
          snapshots_missing: 13_855,
          snapshots_stale: 0,
          coverage_percent: 0.72,
          actor_profile_max_height: 956_412,
          behavior_snapshot_max_height: 956_197,
          checkpoint_lag: 215,
          last_run_status: "completed",
          running_runs: 0
        }
      }
    end

    def control_snapshot
      {
        source:
          ActorLabels::StrictRuleSet::SOURCE,
        rule_version:
          ActorLabels::StrictRuleSet::RULE_VERSION,
        required_behavior_version:
          "strict_v2",
        queue_name:
          "actor_labels_strict",
        queue_size:
          0,
        scheduled_size:
          0,
        worker_busy:
          false,
        worker_present:
          true,
        worker_status: {
          "observed_at" =>
            Time.current.iso8601(6),
          "queue_name" =>
            "actor_labels_strict",
          "write_enabled" =>
            true
        },
        worker_write_observed:
          true,
        worker_write_status_fresh:
          true,
        worker_write_enabled:
          true,
        worker_status_observed_at:
          Time.current,
        lock_present:
          false,
        cursor:
          25,
        work_available:
          true,
        pending_for_labels:
          12,
        cooldown_active:
          false,
        cooldown_remaining_seconds:
          0,
        next_eligible_at:
          nil,
        last_run_status:
          "completed",
        last_run_finished_at:
          Time.current,
        last_runtime_ms:
          42,
        last_run:
          {}
      }
    end
  end
end
