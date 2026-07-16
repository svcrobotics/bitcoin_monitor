# frozen_string_literal: true

require "json"

module ActorProfiles
  class StrictHealthSnapshot
    QUEUE_NAME = "actor_profile_strict"
    PROFILE_VERSION = StrictBuildFromCluster::PROFILE_VERSION
    STALE_AFTER = BuildDispatcher::STALE_AFTER

    def self.call(now: Time.current, sidekiq_runtime: nil, pipeline_decision: nil)
      new(
        now: now,
        sidekiq_runtime: sidekiq_runtime,
        pipeline_decision: pipeline_decision
      ).call
    end

    def initialize(now:, sidekiq_runtime:, pipeline_decision:)
      @now = now
      @sidekiq_runtime_override = sidekiq_runtime
      @pipeline_decision = pipeline_decision
    end

    def call
      database = database_snapshot
      runtime = runtime_snapshot
      admissible = database.dig(:handoffs, :admissible).to_i

      automation_missing =
        runtime[:available] == true &&
        admissible.positive? &&
        runtime.values_at(:queue_size, :scheduled_jobs, :worker_count, :busy_workers)
          .compact.sum.zero?

      status = if runtime[:available] != true
        "unavailable"
      elsif database[:available] != true
        "unavailable"
      elsif database.dig(:address_spend, :lag).to_i.positive? ||
            database.dig(:profiles, :pending).to_i.positive?
        automation_missing ? "warning" : "syncing"
      else
        "healthy"
      end

      database.merge(
        module: "actor_profiles_strict",
        source: "canonical_postgresql_chain",
        generated_at: @now,
        status: status,
        automation: runtime.merge(
          automation_missing: automation_missing
        ),
        admission: {
          allowed: normalized_pipeline_allowed
        },
        issues: issues(database, runtime, automation_missing)
      )
    rescue ActiveRecord::ActiveRecordError
      unavailable_database_snapshot
    end

    private

    def database_snapshot
      connection = ApplicationRecord.connection
      profile_row = connection.select_one(profile_aggregate_sql)
      handoff_rows = ActorProfileBuildAdmission.group(:status).count
      cluster_tip = ClusterProcessedBlock.where(status: "processed").maximum(:height)
      address_spend_tip = AddressSpendProjectionBlock.completed.maximum(:height)
      total_clusters = profile_row.fetch("total_clusters").to_i
      certified = profile_row.fetch("certified_profiles").to_i
      present = profile_row.fetch("profiles_present").to_i
      missing = profile_row.fetch("missing_profiles").to_i
      stale = profile_row.fetch("stale_profiles").to_i

      {
        available: true,
        profiles: {
          total_clusters: total_clusters,
          present: present,
          certified: certified,
          missing: missing,
          stale: stale,
          pending: missing + stale,
          coverage_pct: total_clusters.positive? ? (certified.fdiv(total_clusters) * 100).round(2) : 0.0,
          latest_height: integer_or_nil(profile_row["latest_height"]),
          latest_certified_at: profile_row["latest_certified_at"],
          certified_last_10m: profile_row.fetch("certified_last_10m").to_i,
          certified_last_1h: profile_row.fetch("certified_last_1h").to_i
        },
        handoffs: {
          pending: handoff_rows.fetch("pending", 0),
          processing: handoff_rows.fetch("processing", 0),
          failed: handoff_rows.fetch("failed", 0),
          completed: handoff_rows.fetch("completed", 0),
          stale: stale_handoff_count,
          admissible: admissible_handoff_count,
          oldest_age_seconds: oldest_handoff_age
        },
        address_spend: {
          cluster_tip: integer_or_nil(cluster_tip),
          tip: integer_or_nil(address_spend_tip),
          lag: checkpoint_lag(cluster_tip, address_spend_tip)
        },
        build_metrics: runtime_metrics
      }
    end

    def profile_aggregate_sql
      connection = ApplicationRecord.connection
      version = connection.quote(PROFILE_VERSION)
      ten_minutes_ago = connection.quote(@now - 10.minutes)
      one_hour_ago = connection.quote(@now - 1.hour)
      <<~SQL.squish
        SELECT
          COUNT(clusters.id)::bigint AS total_clusters,
          COUNT(actor_profiles.id)::bigint AS profiles_present,
          COUNT(*) FILTER (WHERE actor_profiles.id IS NULL)::bigint AS missing_profiles,
          COUNT(*) FILTER (
            WHERE actor_profiles.id IS NOT NULL
              AND actor_profiles.cluster_composition_version IS DISTINCT FROM clusters.composition_version
          )::bigint AS stale_profiles,
          COUNT(*) FILTER (
            WHERE actor_profiles.certified_at IS NOT NULL
              AND actor_profiles.dirty IS NOT TRUE
              AND actor_profiles.cluster_composition_version = clusters.composition_version
              AND actor_profiles.last_computed_height IS NOT NULL
              AND actor_profiles.certification_epoch_height = actor_profiles.last_computed_height
              AND actor_profiles.certification_scope = 'strict'
              AND actor_profiles.traits ->> 'profile_version' = #{version}
              AND actor_profiles.metadata ->> 'strict' = 'true'
          )::bigint AS certified_profiles,
          MAX(actor_profiles.last_computed_height) FILTER (
            WHERE actor_profiles.certified_at IS NOT NULL
          ) AS latest_height,
          MAX(actor_profiles.certified_at) AS latest_certified_at,
          COUNT(*) FILTER (WHERE actor_profiles.certified_at >= #{ten_minutes_ago})::bigint AS certified_last_10m,
          COUNT(*) FILTER (WHERE actor_profiles.certified_at >= #{one_hour_ago})::bigint AS certified_last_1h
        FROM clusters
        LEFT JOIN actor_profiles ON actor_profiles.cluster_id = clusters.id
      SQL
    end

    def stale_handoff_count
      ActorProfileBuildAdmission.where(status: "processing")
        .where("claimed_at IS NULL OR claimed_at < ?", @now - STALE_AFTER).count
    end

    def admissible_handoff_count
      BuildDispatcher.claimable_scope(now: @now).count
    end

    def oldest_handoff_age
      created = ActorProfileBuildAdmission.where(status: %w[pending processing failed]).minimum(:created_at)
      created ? [(@now - created).to_f, 0.0].max : nil
    end

    def runtime_metrics
      row = ApplicationRecord.connection.select_one(<<~SQL.squish)
        WITH finite_metrics AS (
          SELECT (metadata ->> 'runtime_ms')::double precision AS runtime_ms
          FROM actor_profiles
          WHERE certified_at IS NOT NULL
            AND metadata ->> 'runtime_ms' ~ '^[0-9]+(?:\\.[0-9]+)?$'
        )
        SELECT
          AVG(runtime_ms) AS average_ms,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY runtime_ms) AS median_ms,
          percentile_cont(0.9) WITHIN GROUP (ORDER BY runtime_ms) AS p90_ms,
          MAX(runtime_ms) AS maximum_ms
        FROM finite_metrics
      SQL
      {
        average_ms: numeric_or_nil(row["average_ms"]),
        median_ms: numeric_or_nil(row["median_ms"]),
        p90_ms: numeric_or_nil(row["p90_ms"]),
        maximum_ms: numeric_or_nil(row["maximum_ms"])
      }
    end

    def runtime_snapshot
      return normalize_runtime(@sidekiq_runtime_override) if @sidekiq_runtime_override

      require "sidekiq/api"
      queue = Sidekiq::Queue.new(QUEUE_NAME)
      processes = Sidekiq::ProcessSet.new.select { |process| Array(process["queues"]).include?(QUEUE_NAME) }
      {
        available: true,
        queue_name: QUEUE_NAME,
        queue_size: queue.size,
        queue_latency_seconds: numeric_or_nil(queue.latency),
        scheduled_jobs: Sidekiq::ScheduledSet.new.count { |job| job.queue.to_s == QUEUE_NAME },
        worker_count: processes.size,
        busy_workers: processes.sum { |process| process["busy"].to_i }
      }
    rescue StandardError
      unavailable_runtime
    end

    def normalize_runtime(value)
      return unavailable_runtime unless value.is_a?(Hash) && value[:available] == true

      {
        available: true,
        queue_name: QUEUE_NAME,
        queue_size: value[:queue_size].to_i,
        queue_latency_seconds: numeric_or_nil(value[:queue_latency_seconds]),
        scheduled_jobs: value[:scheduled_jobs].to_i,
        worker_count: value[:worker_count].to_i,
        busy_workers: value[:busy_workers].to_i
      }
    end

    def unavailable_runtime
      {
        available: false,
        queue_name: QUEUE_NAME,
        queue_size: nil,
        queue_latency_seconds: nil,
        scheduled_jobs: nil,
        worker_count: nil,
        busy_workers: nil,
        automation_missing: false
      }
    end

    def unavailable_database_snapshot
      {
        module: "actor_profiles_strict",
        source: "canonical_postgresql_chain",
        generated_at: @now,
        available: false,
        status: "unavailable",
        profiles: unavailable_profile_metrics,
        handoffs: unavailable_handoff_metrics,
        address_spend: { cluster_tip: nil, tip: nil, lag: nil },
        build_metrics: { average_ms: nil, median_ms: nil, p90_ms: nil, maximum_ms: nil },
        automation: unavailable_runtime,
        admission: { allowed: normalized_pipeline_allowed },
        issues: ["postgresql_unavailable"]
      }
    end

    def unavailable_profile_metrics
      %i[total_clusters present certified missing stale pending coverage_pct latest_height latest_certified_at certified_last_10m certified_last_1h].to_h { |key| [key, nil] }
    end

    def unavailable_handoff_metrics
      %i[pending processing failed completed stale admissible oldest_age_seconds].to_h { |key| [key, nil] }
    end

    def issues(database, runtime, automation_missing)
      result = []
      result << "sidekiq_unavailable" unless runtime[:available]
      result << "address_spend_lag" if database.dig(:address_spend, :lag).to_i.positive?
      result << "failed_handoffs" if database.dig(:handoffs, :failed).to_i.positive?
      result << "stale_handoffs" if database.dig(:handoffs, :stale).to_i.positive?
      result << "automation_missing" if automation_missing
      result << "pipeline_controller_refused" if normalized_pipeline_allowed == false
      result
    end

    def checkpoint_lag(cluster_tip, projection_tip)
      return nil unless cluster_tip && projection_tip
      [cluster_tip.to_i - projection_tip.to_i, 0].max
    end

    def normalized_pipeline_allowed
      return nil unless @pipeline_decision.is_a?(Hash)
      value = @pipeline_decision[:allowed]
      [true, false].include?(value) ? value : nil
    end

    def integer_or_nil(value)
      value.nil? ? nil : value.to_i
    end

    def numeric_or_nil(value)
      number = Float(value)
      number.finite? && !number.negative? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
