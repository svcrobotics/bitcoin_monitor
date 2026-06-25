# frozen_string_literal: true

require "json"
require "sidekiq/api"

module ActorLabels
  class StrictHealthSnapshot
    TARGET_CLASS = "ActorLabels::StrictBatchJob"
    QUEUE_NAME = "actor_labels_strict"

    RULE_SET = ActorLabels::StrictRuleSetV2

    CURSOR_KEY = ActorLabels::StrictBatchJob::CURSOR_KEY
    LOCK_KEY = ActorLabels::StrictBatchJob::LOCK_KEY
    SCHEDULE_KEY = ActorLabels::StrictBatchJob::SCHEDULE_KEY
    LAST_RUN_KEY = ActorLabels::StrictBatchJob::LAST_RUN_KEY

    def self.call
      new.call
    end

    def call
      profile_snapshot =
        ActorProfiles::StrictHealthSnapshot.call

      profile_progress =
        profile_snapshot[:progress] || {}

      profile_integrity =
        profile_snapshot[:integrity] || {}

      tip =
        cluster_tip

      total_clusters =
        profile_progress[:total_clusters].to_i

      total_profiles =
        profile_progress[:actor_profiles].to_i

      certified_from_snapshot =
        profile_progress[:certified_profiles].to_i

      missing_profiles =
        profile_progress[:missing_profiles].to_i

      stale_profiles =
        profile_progress[:stale_profiles].to_i

      pending_profiles =
        missing_profiles +
        stale_profiles

      certified_scope =
        ActorProfiles::CertifiedScope.call

      certified_profiles =
        certified_scope.count

      certified_profile_max_id =
        certified_scope.maximum(:id).to_i

      process_count =
        strict_processes.size

      queue_size =
        Sidekiq::Queue.new(QUEUE_NAME).size

      scheduled_jobs =
        count_jobs(
          Sidekiq::ScheduledSet.new
        )

      retry_jobs =
        count_jobs(
          Sidekiq::RetrySet.new
        )

      dead_jobs =
        count_jobs(
          Sidekiq::DeadSet.new
        )

      active_workers =
        count_active_workers

      redis =
        redis_state

      last_run =
        parse_json(
          redis[:last_run]
        )

      last_batch =
        last_run["batch"] || {}

      write_enabled =
        write_enabled?

      automation_present =
        queue_size.positive? ||
        scheduled_jobs.positive? ||
        active_workers.positive? ||
        redis[:scheduled_marker].present?

      coverage_pct =
        percentage(
          certified_profiles,
          total_clusters
        )

      cursor_value =
        redis[:cursor].to_i

      last_run_scanned =
        last_batch["scanned"].to_i

      last_run_started_from_zero =
        last_run["after_id"].to_i.zero?

      last_run_coverage_count =
        if last_run_started_from_zero &&
           last_run_scanned.positive?
          [
            last_run_scanned,
            certified_profiles
          ].min
        elsif cursor_value.positive?
          certified_scope
            .where(
              "actor_profiles.id <= ?",
              cursor_value
            )
            .count
        else
          0
        end

      pending_since_last_run =
        [
          certified_profiles -
            last_run_coverage_count,
          0
        ].max

      completed_cycle =
        certified_profiles.positive? &&
        last_run_coverage_count >=
          certified_profiles

      cycle_pct =
        percentage(
          last_run_coverage_count,
          certified_profiles
        )

      strict_scope =
        ActorLabel.where(
          source: RULE_SET::SOURCE
        )

      strict_labels =
        strict_scope.count

      issues = []

      issues <<
        "cluster_tip_missing" if tip.zero?

      issues <<
        "worker_missing" if process_count.zero?

      issues <<
        "multiple_workers=#{process_count}" if process_count > 1

      issues <<
        "retry_jobs_present=#{retry_jobs}" if retry_jobs.positive?

      issues <<
        "dead_jobs_present=#{dead_jobs}" if dead_jobs.positive?

      issues <<
        "last_batch_failed" if last_run["ok"] == false

      if certified_profiles != certified_from_snapshot
        issues <<
          "certified_scope_mismatch=" \
          "#{certified_profiles}/#{certified_from_snapshot}"
      end

      invalid_profile_refs =
        profile_integrity[
          :invalid_profile_refs
        ].to_i

      if invalid_profile_refs.positive?
        issues <<
          "invalid_profile_refs=#{invalid_profile_refs}"
      end

      unless profile_integrity[
        :profile_partition_ok
      ] == true
        issues <<
          "actor_profile_partition_invalid"
      end

      if profile_snapshot[:status].to_s == "critical"
        issues <<
          "actor_profile_critical"
      end

      if write_enabled &&
         !automation_present
        issues <<
          "automation_missing"
      end

      status =
        if issues.any?
          "critical"
        elsif !write_enabled
          "dry_run"
        elsif pending_profiles.positive?
          "syncing"
        else
          "healthy"
        end

      {
        status: status,

        source:
          "actor_labels_strict_health_snapshot_v2",

        rule_version:
          RULE_SET::RULE_VERSION,

        generated_at:
          Time.current,

        pipeline: {
          cluster_tip:
            tip,

          required_profile_version:
            RULE_SET::PROFILE_VERSION,

          freshness_basis:
            RULE_SET::FRESHNESS_BASIS,

          write_enabled:
            write_enabled,

          mode:
            write_enabled ?
              "write_enabled" :
              "dry_run",

          automation_present:
            automation_present
        },

        actor_profiles: {
          total_clusters:
            total_clusters,

          total_profiles:
            total_profiles,

          certified:
            certified_profiles,

          certified_pct:
            coverage_pct,

          expected_certified:
            certified_from_snapshot,

          missing:
            missing_profiles,

          stale:
            stale_profiles,

          pending:
            pending_profiles,

          certified_scope_matches:
            certified_profiles ==
              certified_from_snapshot,

          certified_profile_max_id:
            certified_profile_max_id,

          recent:
            certified_profiles,

          recent_pct:
            coverage_pct,

          total:
            total_profiles,

          stale_or_missing:
            pending_profiles
        },

        actor_labels: {
          total:
            ActorLabel.count,

          strict_total:
            strict_labels,

          by_label:
            strict_scope
              .group(:label)
              .count
        },

        rules: {
          whale_like: {
            enabled:
              true,

            min_whale_score:
              RULE_SET::WHALE_MIN_SCORE,

            min_balance_btc:
              RULE_SET::WHALE_MIN_BALANCE_BTC.to_s("F"),

            max_exchange_score:
              RULE_SET::MAX_EXCHANGE_SCORE_FOR_WHALE,

            max_service_score:
              RULE_SET::MAX_SERVICE_SCORE_FOR_WHALE
          }
        },

        automation: {
          queue_name:
            QUEUE_NAME,

          processes:
            process_count,

          queue_size:
            queue_size,

          active_workers:
            active_workers,

          scheduled_jobs:
            scheduled_jobs,

          retry_jobs:
            retry_jobs,

          dead_jobs:
            dead_jobs,

          automation_present:
            automation_present,

          automation_ok:
            issues.empty?,

          paused_intentionally:
            !write_enabled &&
            !automation_present
        },

        cursor: {
          current:
            cursor_value,

          certified_profile_max_id:
            certified_profile_max_id,

          processed_in_cycle:
            last_run_coverage_count,

          analyzed_in_last_run:
            last_run_coverage_count,

          pending_since_last_run:
            pending_since_last_run,

          certified_profiles:
            certified_profiles,

          cycle_pct:
            cycle_pct,

          completed_cycle:
            completed_cycle
        },

        redis: {
          lock_present:
            redis[:lock].present?,

          scheduled_marker_present:
            redis[:scheduled_marker].present?
        },

        last_run:
          last_run,

        issues:
          issues
      }
    end

    private

    def cluster_tip
      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
        .to_i
    end

    def write_enabled?
      ActiveModel::Type::Boolean
        .new
        .cast(
          ENV.fetch(
            "ACTOR_LABEL_WRITE_ENABLED",
            "false"
          )
        )
    end

    def strict_processes
      Sidekiq::ProcessSet
        .new
        .select do |process|
          Array(
            process["queues"]
          ).include?(QUEUE_NAME) &&
            process["quiet"].to_s != "true"
        end
    end

    def count_jobs(set)
      set.count do |job|
        target_job?(job)
      end
    end

    def count_active_workers
      Sidekiq::WorkSet
        .new
        .count do |_process_id, _thread_id, work|
          target_job?(work)
        end
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_labels_strict_health_v2] " \
        "active_worker_count_failed " \
        "#{error.class}: #{error.message}"
      )

      0
    end

    def target_job?(item)
      payload_for(item)
        .to_s
        .include?(TARGET_CLASS)
    end

    def payload_for(item)
      raw =
        if item.respond_to?(:payload)
          item.payload
        elsif item.respond_to?(:item)
          item.item
        elsif item.instance_variable_defined?(
          :@hsh
        )
          item.instance_variable_get(
            :@hsh
          )
        else
          {}
        end

      payload =
        if raw.is_a?(Hash)
          raw["payload"] || raw
        else
          raw
        end

      if payload.is_a?(String)
        JSON.parse(payload)
      else
        payload
      end
    rescue JSON::ParserError
      raw
    end

    def redis_state
      Sidekiq.redis do |redis|
        {
          cursor:
            redis.get(CURSOR_KEY),

          lock:
            redis.get(LOCK_KEY),

          scheduled_marker:
            redis.get(SCHEDULE_KEY),

          last_run:
            redis.get(LAST_RUN_KEY)
        }
      end
    end

    def parse_json(value)
      return {} if value.blank?

      JSON.parse(value)
    rescue JSON::ParserError
      {}
    end

    def percentage(value, total)
      return 0.0 if total.to_i.zero?

      (
        value.to_f /
        total.to_f *
        100
      ).round(2)
    end
  end
end
