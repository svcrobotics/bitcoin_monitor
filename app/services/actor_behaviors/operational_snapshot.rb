# frozen_string_literal: true

module ActorBehaviors
  class OperationalSnapshot
    MODE = "shadow"

    def self.call
      new.call
    end

    def call
      generated_at =
        Time.current

      certified_scope =
        ActorBehaviors::SnapshotStateScope
          .certified_profiles

      current_scope =
        ActorBehaviors::SnapshotStateScope
          .current_profiles

      missing_scope =
        ActorBehaviors::SnapshotStateScope
          .missing_profiles

      stale_scope =
        ActorBehaviors::SnapshotStateScope
          .stale_profiles

      actor_profiles_certified =
        certified_scope.count

      snapshots_current =
        current_scope.count

      snapshots_missing =
        missing_scope.count

      snapshots_stale =
        stale_scope.count

      actor_profile_max_height =
        certified_scope.maximum(
          :last_computed_height
        )

      behavior_snapshot_max_height =
        current_scope.maximum(
          "actor_behavior_snapshots.profile_height"
        )

      last_run =
        ActorBehaviorRun
          .order(started_at: :desc, id: :desc)
          .first

      {
        mode: MODE,
        behavior_version:
          ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,

        actor_profiles_total:
          ActorProfile.count,

        actor_profiles_certified:
          actor_profiles_certified,

        snapshots_total:
          ActorBehaviorSnapshot.count,

        snapshots_current:
          snapshots_current,

        snapshots_missing:
          snapshots_missing,

        snapshots_stale:
          snapshots_stale,

        snapshots_non_certified_status:
          ActorBehaviorSnapshot
            .where.not(status: "certified")
            .count,

        coverage_ratio:
          coverage_ratio(
            snapshots_current,
            actor_profiles_certified
          ),

        coverage_percent:
          coverage_percent(
            snapshots_current,
            actor_profiles_certified
          ),

        latest_computed_at:
          ActorBehaviorSnapshot.maximum(:computed_at),

        oldest_current_computed_at:
          current_scope.minimum(
            "actor_behavior_snapshots.computed_at"
          ),

        oldest_missing_profile_updated_at:
          missing_scope.minimum(:updated_at),

        oldest_stale_profile_updated_at:
          stale_scope.minimum(:updated_at),

        actor_profile_max_height:
          actor_profile_max_height,

        behavior_snapshot_max_height:
          behavior_snapshot_max_height,

        checkpoint_lag:
          checkpoint_lag(
            actor_profile_max_height,
            behavior_snapshot_max_height
          ),

        behavior_versions:
          grouped_counts(:behavior_version),

        snapshot_statuses:
          grouped_counts(:status),

        runs_total:
          ActorBehaviorRun.count,

        last_run_id:
          last_run&.id,

        last_run_status:
          last_run&.status,

        last_run_trigger:
          last_run&.trigger,

        last_run_started_at:
          last_run&.started_at,

        last_run_finished_at:
          last_run&.finished_at,

        last_run_duration_ms:
          last_run&.duration_ms,

        last_run_counts:
          last_run_counts(last_run),

        last_run_reasons:
          last_run&.reasons || {},

        last_successful_run_at:
          ActorBehaviorRun
            .successful
            .maximum(:finished_at),

        running_runs:
          ActorBehaviorRun.running.count,

        stale_running_runs:
          ActorBehaviorRun.stale_running.count,

        coverage_invariant_ok:
          coverage_invariant_ok?(
            current: snapshots_current,
            missing: snapshots_missing,
            stale: snapshots_stale,
            certified: actor_profiles_certified
          ),

        current_definition:
          "sql_current_without_global_fingerprint_recalculation",

        generated_at:
          generated_at
      }
    end

    private

    def coverage_ratio(current, total)
      return 0.0 if total.to_i.zero?

      current.to_f / total.to_f
    end

    def coverage_percent(current, total)
      (coverage_ratio(current, total) * 100).round(2)
    end

    def checkpoint_lag(actor_profile_height, behavior_height)
      return nil if behavior_height.nil?

      [
        actor_profile_height.to_i -
          behavior_height.to_i,
        0
      ].max
    end

    def grouped_counts(column)
      ActorBehaviorSnapshot
        .group(column)
        .count
        .transform_keys do |key|
          key.presence || "nil"
        end
    end

    def last_run_counts(run)
      return {} if run.blank?

      {
        selected: run.selected,
        missing_selected: run.missing_selected,
        stale_selected: run.stale_selected,
        created: run.created_count,
        updated: run.updated_count,
        unchanged: run.unchanged_count,
        deferred: run.deferred_count,
        failed: run.failed_count
      }
    end

    def coverage_invariant_ok?(
      current:,
      missing:,
      stale:,
      certified:
    )
      current.to_i +
        missing.to_i +
        stale.to_i ==
        certified.to_i
    end
  end
end
