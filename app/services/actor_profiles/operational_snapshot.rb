# frozen_string_literal: true

require "json"

module ActorProfiles
  class OperationalSnapshot
    CACHE_KEY =
      "actor_profiles:operational_snapshot:v2"

    RECENT_BATCHES_KEY =
      "actor_profiles:operational_snapshot:recent_batches"

    STRICT_QUEUE =
      "actor_profile_strict"

    RECENT_BATCHES_LIMIT = 5
    CACHE_STALE_AFTER_SECONDS_ENV =
      "ACTOR_PROFILE_OPERATIONAL_SNAPSHOT_STALE_AFTER_SECONDS"

    DEFAULT_CACHE_STALE_AFTER_SECONDS = 300

    class << self
      def read
        new.read
      end

      def refresh!
        new.refresh!
      end

      def refresh_from_batch(result)
        new.refresh_from_batch(result)
      end

      def mark_waiting(reason:, result: {})
        new.mark_waiting(
          reason: reason,
          result: result
        )
      end
    end

    def read
      require "sidekiq/api"

      snapshot =
        cached_snapshot

      snapshot =
        snapshot_with_backlog_fallback(
          snapshot
        )

      runtime =
        runtime_snapshot

      certification =
        symbolize(
          snapshot[:certification]
        ) || {}

      epoch_active =
        certification[:epoch_active] == true

      epoch_inactive =
        certification[:epoch_active] == false

      pending =
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        )

      pending =
        snapshot.dig(
          :progress,
          :pending_profiles
        ) if pending.nil?

      pending =
        pending.to_i

      address_spend =
        address_spend_snapshot

      address_spend_sync =
        symbolize(
          address_spend[:sync]
        ) || {}

      waiting_for_address_spend =
        epoch_active &&
        pending.positive? &&
        address_spend[:available] == true &&
        address_spend_sync[
          :caught_up_to_cluster
        ] != true

      pipeline_state =
        if epoch_inactive
          "inactive"
        elsif waiting_for_address_spend
          "waiting_for_address_spend"
        else
          pipeline_state_for(
            runtime: runtime,
            pending: pending
          )
        end

      automation_ok =
        epoch_inactive ||
        waiting_for_address_spend ||
        automation_ok?(
          runtime: runtime,
          pending: pending
        )

      issues =
        Array(
          snapshot[:issues]
        ).reject do |issue|
          issue.to_s ==
            "automation_missing"
        end

      if runtime[:dead_jobs].positive?
        issues << "dead_jobs_present"
      end

      if !automation_ok &&
         pending.positive? &&
         !waiting_for_address_spend
        issues << "automation_missing"
      end

      base_status =
        snapshot[:status].to_s

      status =
        if snapshot[:available] != true
          "unknown"
        elsif epoch_inactive
          "inactive"
        elsif base_status == "critical" ||
              runtime[:dead_jobs].positive?
          "critical"
        elsif waiting_for_address_spend
          "syncing"
        elsif !automation_ok &&
              pending.positive?
          "warning"
        elsif pending.positive? ||
              base_status == "syncing"
          "syncing"
        elsif base_status == "warning"
          "warning"
        else
          "healthy"
        end

      wait_reason =
        if epoch_inactive
          "certification_epoch_inactive"
        elsif waiting_for_address_spend
          "address_spend_projection_not_ready"
        elsif !automation_ok &&
              pending.positive?
          "automation_missing"
        else
          (
            symbolize(
              snapshot[:activity]
            ) || {}
          )[:wait_reason]
        end

      snapshot.merge(
        status: status,

        activity:
          (
            symbolize(
              snapshot[:activity]
            ) || {}
          ).merge(
            pipeline_state:
              pipeline_state,

            wait_reason:
              wait_reason
          ),

        dependencies:
          (
            symbolize(
              snapshot[:dependencies]
            ) || {}
          ).merge(
            address_spend_projection:
              address_spend
          ),

        automation: {
          queue_name:
            STRICT_QUEUE,

          process_present:
            runtime[:process_present],

          process_count:
            runtime[:process_count],

          busy_workers:
            runtime[:busy_workers],

          queue_size:
            runtime[:queue_size],

          scheduled_jobs:
            runtime[:scheduled_jobs],

          lock_ttl:
            runtime[:lock_ttl],

          schedule_marker_ttl:
            runtime[:schedule_marker_ttl],

          retries:
            runtime[:retries],

          dead_jobs:
            runtime[:dead_jobs],

          automation_ok:
            automation_ok
        },

        current_batch:
          ActorProfiles::
            BatchProgress.read,

        recent_batches:
          recent_batches,

        issues:
          issues.uniq
      )
    rescue StandardError => error
      Rails.logger.error(
        "[actor_profile_operational_snapshot] "         "#{error.class}: #{error.message}"
      )

      unavailable_snapshot.merge(
        status: "critical",
        issues: ["snapshot_error"],
        error:
          "#{error.class}: #{error.message}"
      )
    end

    def refresh!
      health =
        symbolize(
          ActorProfiles::
            StrictHealthSnapshot.call
        )

      epoch_inactive =
        health.dig(
          :certification,
          :epoch_active
        ) == false

      snapshot = {
        module:
          "actor_profiles_strict",

        source:
          "actor_profiles_operational_snapshot",

        available:
          true,

        generated_at:
          Time.current,

        status:
          health[:status],

        verdict:
          health[:verdict],

        sync:
          health[:sync] || {},

        progress:
          health[:progress] || {},

        certification:
          health[:certification] || {},

        integrity:
          health[:integrity] || {},

        activity: {
          pipeline_state:
            epoch_inactive ?
              "inactive" :
              "waiting",

          wait_reason:
            epoch_inactive ?
              "certification_epoch_inactive" :
              nil
        },

        last_batch:
          cached_snapshot[:last_batch],

        issues:
          Array(
            health[:issues]
          )
      }

      write_snapshot(snapshot)
      read
    end

    def refresh_from_batch(result)
      result =
        symbolize(result)

      epoch =
        ActorProfiles::
          CertificationEpoch::
          current

      return refresh! unless epoch

      if result[:status].to_s ==
         "deferred"
        refresh! unless
          cached_snapshot.dig(
            :certification,
            :epoch_active
          ) == true

        return mark_waiting(
          reason:
            result[:reason] ||
            "batch_deferred",

          result:
            result
        )
      end

      cluster_tip =
        result[:cluster_tip].to_i

      total_clusters =
        ActorProfiles::
          CertificationTargetScope
          .call(
            checkpoint_height:
              cluster_tip
          )
          .count

      historical_clusters_outside_epoch =
        historical_clusters_outside_epoch_count(
          epoch
        )

      missing_profiles =
        result[
          :missing_profiles_count
        ].to_i

      stale_profiles =
        result[
          :stale_profiles_count
        ].to_i

      certified_profiles = [
        total_clusters -
          missing_profiles -
          stale_profiles,
        0
      ].max

      pending_profiles =
        missing_profiles +
        stale_profiles

      completion_pct =
        if total_clusters.positive?
          (
            certified_profiles.to_f /
            total_clusters *
            100
          ).round(2)
        else
          0.0
        end

      profile_max_height =
        ActorProfiles::
          CertifiedScope
          .call
          .maximum(
            :last_computed_height
          )
          .to_i

      last_batch = {
        completed_at:
          Time.current,

        selected:
          result[:selected].to_i,

        built:
          result[:built].to_i,

        deferred:
          result[:deferred].to_i,

        failed:
          result[:failed].to_i,

        duration_ms:
          result[:duration_ms].to_i,

        avg_runtime_ms:
          result[:avg_runtime_ms].to_i,

        min_runtime_ms:
          result[:min_runtime_ms],

        max_runtime_ms:
          result[:max_runtime_ms],

        cluster_tip:
          cluster_tip,

        selection_ms:
          result[:selection_ms].to_i,

        build_loop_ms:
          result[:build_loop_ms].to_i,

        counts_ms:
          result[:counts_ms].to_i,

        successful_runtime_ms:
          result[
            :successful_runtime_ms
          ].to_i,

        deferred_or_overhead_runtime_ms:
          result[
            :deferred_or_overhead_runtime_ms
          ].to_i,

        unattributed_runtime_ms:
          result[
            :unattributed_runtime_ms
          ].to_i,

        deferred_samples:
          Array(
            result[:deferred_samples]
          ).first(10),

        failures:
          Array(
            result[:failures]
          ).first(10)
      }

      snapshot = {
        module:
          "actor_profiles_strict",

        source:
          "actor_profiles_operational_snapshot",

        available:
          true,

        generated_at:
          Time.current,

        status:
          pending_profiles.positive? ?
            "syncing" :
            "healthy",

        sync: {
          layer1_tip:
            result[:layer1_tip].to_i,

          cluster_tip:
            cluster_tip,

          strict_tips_aligned:
            result[:layer1_tip].to_i ==
              cluster_tip,

          profile_max_height:
            profile_max_height
        },

        progress: {
          total_clusters:
            total_clusters,

          active_clusters_since_epoch:
            total_clusters,

          historical_clusters_outside_epoch:
            historical_clusters_outside_epoch,

          profiles_in_scope:
            [
              total_clusters -
                missing_profiles,
              0
            ].max,

          actor_profiles:
            result[
              :actor_profiles_count
            ].to_i,

          missing_profiles:
            missing_profiles,

          stale_profiles:
            stale_profiles,

          certified_profiles:
            certified_profiles,

          certified_profiles_since_epoch:
            certified_profiles,

          pending_profiles:
            pending_profiles,

          pending_profiles_since_epoch:
            pending_profiles,

          completion_pct:
            completion_pct
        },

        certification: {
          epoch_active:
            true,

          certification_epoch_height:
            epoch.start_height,

          certification_scope:
            ActorProfile::
              CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,

          required_profile_version:
            ActorProfiles::
              StrictBuildFromCluster::
              PROFILE_VERSION
        },

        integrity: {
          profile_partition_delta:
            0,

          profile_partition_ok:
            true
        },

        activity: {
          pipeline_state:
            pending_profiles.positive? ?
              "scheduled" :
              "idle_synced",

          wait_reason:
            nil
        },

        last_batch:
          last_batch,

        issues:
          []
      }

      write_snapshot(snapshot)
      record_recent_batch(last_batch)

      read
    end

    def mark_waiting(reason:, result: {})
      result = symbolize(result)
      snapshot = cached_snapshot

      snapshot[:generated_at] =
        Time.current

      snapshot[:sync] =
        (
          symbolize(snapshot[:sync]) || {}
        ).merge(
          layer1_tip:
            result[:layer1_tip],

          cluster_tip:
            result[:cluster_tip]
        ).compact

      snapshot[:activity] =
        (
          symbolize(snapshot[:activity]) || {}
        ).merge(
          pipeline_state:
            "waiting",

          wait_reason:
            reason.to_s
        )

      write_snapshot(snapshot)
      read
    end

    private

    def cached_snapshot
      raw =
        Sidekiq.redis do |redis|
          redis.get(CACHE_KEY)
        end

      return unavailable_snapshot if raw.blank?

      symbolize(
        ActiveSupport::JSON.decode(raw)
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_profile_operational_snapshot] " \
        "cache_read_failed " \
        "#{error.class}: #{error.message}"
      )

      unavailable_snapshot
    end

    def snapshot_with_backlog_fallback(snapshot)
      snapshot =
        symbolize(snapshot) || unavailable_snapshot

      return snapshot unless
        cache_unreliable?(snapshot)

      epoch =
        ActorProfiles::
          CertificationEpoch::
          current

      return inactive_cache_fallback(snapshot) unless
        epoch

      cluster_tip =
        ClusterProcessedBlock
          .where(status: "processed")
          .maximum(:height)
          .to_i

      return snapshot unless
        cluster_tip.positive?

      pending_lower_bound =
        fallback_pending_lower_bound(
          checkpoint_height: cluster_tip,
          epoch: epoch
        )

      progress =
        symbolize(snapshot[:progress]) || {}

      current_pending =
        if progress.key?(
          :pending_profiles_since_epoch
        )
          progress[:pending_profiles_since_epoch].to_i
        else
          progress[:pending_profiles].to_i
        end

      pending =
        [
          current_pending,
          pending_lower_bound
        ].max

      certification =
        (
          symbolize(snapshot[:certification]) || {}
        ).merge(
          epoch_active: true,
          certification_epoch_height:
            epoch.start_height,
          certification_scope:
            ActorProfile::
              CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,
          required_profile_version:
            ActorProfiles::
              StrictBuildFromCluster::
              PROFILE_VERSION
        )

      sync =
        (
          symbolize(snapshot[:sync]) || {}
        ).merge(
          cluster_tip: cluster_tip
        )

      fallback_progress =
        progress.merge(
          pending_profiles: pending,
          pending_profiles_since_epoch:
            pending
        )

      status =
        if pending.positive?
          "syncing"
        elsif snapshot[:status].present? &&
              snapshot[:status].to_s != "unknown"
          snapshot[:status]
        else
          "healthy"
        end

      issues =
        Array(snapshot[:issues]) |
        [
          cache_unavailable?(snapshot) ?
            "operational_cache_missing" :
            "operational_cache_stale",
          "operational_backlog_fallback"
        ]

      snapshot.merge(
        available: true,
        status: status,
        sync: sync,
        progress: fallback_progress,
        certification: certification,
        issues: issues
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_profile_operational_snapshot] " \
        "backlog_fallback_failed " \
        "#{error.class}: #{error.message}"
      )

      snapshot
    end

    def cache_unreliable?(snapshot)
      cache_unavailable?(snapshot) ||
        cache_stale?(snapshot)
    end

    def inactive_cache_fallback(snapshot)
      progress =
        symbolize(snapshot[:progress]) || {}

      snapshot.merge(
        available: true,
        status: "inactive",
        progress:
          progress.merge(
            pending_profiles: 0,
            pending_profiles_since_epoch: 0
          ),
        certification:
          (
            symbolize(snapshot[:certification]) || {}
          ).merge(
            epoch_active: false,
            required_profile_version:
              ActorProfiles::
                StrictBuildFromCluster::
                PROFILE_VERSION
          ),
        activity:
          (
            symbolize(snapshot[:activity]) || {}
          ).merge(
            pipeline_state: "inactive",
            wait_reason:
              "certification_epoch_inactive"
          ),
        issues:
          (
            Array(snapshot[:issues]) |
              [
                "certification_epoch_inactive"
              ]
          )
      )
    end

    def cache_unavailable?(snapshot)
      snapshot[:available] != true ||
        Array(snapshot[:issues])
          .map(&:to_s)
          .include?(
            "operational_cache_missing"
          )
    end

    def cache_stale?(snapshot)
      generated_at =
        parse_time(snapshot[:generated_at])

      return true unless generated_at

      Time.current - generated_at >
        cache_stale_after_seconds
    end

    def cache_stale_after_seconds
      Integer(
        ENV.fetch(
          CACHE_STALE_AFTER_SECONDS_ENV,
          DEFAULT_CACHE_STALE_AFTER_SECONDS
            .to_s
        )
      )
    rescue ArgumentError, TypeError
      DEFAULT_CACHE_STALE_AFTER_SECONDS
    end

    def fallback_pending_lower_bound(
      checkpoint_height:,
      epoch:
    )
      scope =
        ActorProfiles::
          CertificationTargetScope
          .call(
            checkpoint_height:
              checkpoint_height
          )

      missing =
        scope
          .left_outer_joins(:actor_profile)
          .where(actor_profiles: { id: nil })
          .limit(1)
          .exists? ? 1 : 0

      stale =
        ActorProfile
          .joins(:cluster)
          .where(
            clusters: {
              id: scope.select(:id)
            }
          )
          .where(
            fallback_stale_condition(epoch)
          )
          .limit(1)
          .exists? ? 1 : 0

      missing + stale
    end

    def fallback_stale_condition(epoch)
      [
        <<~SQL.squish,
          actor_profiles.dirty IS TRUE

          OR actor_profiles.cluster_composition_version
            IS DISTINCT FROM
            clusters.composition_version

          OR COALESCE(
            actor_profiles.last_computed_height,
            0
          ) < COALESCE(
            clusters.last_seen_height,
            0
          )

          OR COALESCE(
            actor_profiles.traits ->> 'profile_version',
            ''
          ) <> ?

          OR COALESCE(
            actor_profiles.metadata ->> 'strict',
            'false'
          ) <> 'true'

          OR actor_profiles.certification_epoch_height
            IS DISTINCT FROM
            ?

          OR COALESCE(
            actor_profiles.certification_scope,
            ''
          ) <> ?

          OR actor_profiles.certified_at IS NULL
        SQL
        ActorProfiles::
          StrictBuildFromCluster::
          PROFILE_VERSION,
        epoch.start_height.to_i,
        ActorProfile::
          CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH
      ]
    end

    def parse_time(value)
      return value if value.is_a?(Time)

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def write_snapshot(snapshot)
      encoded =
        ActiveSupport::JSON.encode(snapshot)

      Sidekiq.redis do |redis|
        redis.set(
          CACHE_KEY,
          encoded
        )
      end

      snapshot
    end

    def base_eligible_clusters_scope
      if include_singletons?
        Cluster.where(
          "clusters.address_count > 0"
        )
      else
        Cluster.where(
          "clusters.address_count > 1"
        )
      end
    end

    def historical_clusters_outside_epoch_count(
      epoch
    )
      base_eligible_clusters_scope
        .where(
          "COALESCE(clusters.last_seen_height, 0) < ?",
          epoch.start_height
        )
        .count
    end

    def include_singletons?
      ActiveModel::Type::Boolean
        .new
        .cast(
          ENV.fetch(
            "ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS",
            "false"
          )
        )
    end

    def address_spend_snapshot
      symbolize(
        AddressSpendStats::
          OperationalSnapshot.call
      ) || {}
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_profile_operational_snapshot] " \
        "address_spend_snapshot_failed " \
        "#{error.class}: #{error.message}"
      )

      {
        available: false,
        status: "unknown",

        sync: {
          cluster_tip: nil,
          projection_tip: nil,
          lag: nil,
          next_record_height: nil,
          caught_up_to_cluster: false
        },

        activity: {
          processing_height: nil
        },

        automation: {
          process_present: false,
          busy_workers: 0,
          queue_size: 0
        },

        issues: [
          "address_spend_snapshot_error"
        ]
      }
    end

    def runtime_snapshot
      processes =
        Sidekiq::ProcessSet.new.select do |process|
          Array(process["queues"])
            .include?(STRICT_QUEUE)
        end

      queue_size =
        Sidekiq::Queue
          .new(STRICT_QUEUE)
          .size

      scheduled_jobs =
        Sidekiq::ScheduledSet.new.count do |job|
          job.queue == STRICT_QUEUE ||
            job.item.to_s.include?(
              "ActorProfiles::StrictBatchJob"
            )
        end

      retries =
        Sidekiq::RetrySet.new.count do |job|
          job.queue == STRICT_QUEUE
        end

      dead_jobs =
        Sidekiq::DeadSet.new.count do |job|
          job.queue == STRICT_QUEUE
        end

      redis =
        Sidekiq.redis do |connection|
          {
            lock_ttl:
              connection.ttl(
                ActorProfiles::
                  StrictBatchJob::
                  LOCK_KEY
              ),

            schedule_marker_ttl:
              connection.ttl(
                ActorProfiles::
                  StrictBatchJob::
                  SCHEDULE_KEY
              )
          }
        end

      {
        process_present:
          processes.any?,

        process_count:
          processes.size,

        busy_workers:
          processes.sum {
            |process|
            process["busy"].to_i
          },

        queue_size:
          queue_size,

        scheduled_jobs:
          scheduled_jobs,

        retries:
          retries,

        dead_jobs:
          dead_jobs,

        lock_ttl:
          redis[:lock_ttl].to_i,

        schedule_marker_ttl:
          redis[:schedule_marker_ttl]
            .to_i
      }
    end

    def pipeline_state_for(runtime:, pending:)
      if !runtime[:process_present]
        "worker_missing"
      elsif runtime[:busy_workers].positive? ||
            runtime[:lock_ttl].positive?
        "active"
      elsif runtime[:queue_size].positive?
        "queued"
      elsif runtime[:scheduled_jobs].positive? ||
            runtime[:schedule_marker_ttl]
              .positive?
        "scheduled"
      elsif pending.zero?
        "idle_synced"
      elsif runtime[:process_present]
        "automation_missing"
      else
        "worker_missing"
      end
    end

    def automation_ok?(runtime:, pending:)
      return false unless runtime[
        :process_present
      ]

      pending.zero? ||
        runtime[:busy_workers].positive? ||
        runtime[:lock_ttl].positive? ||
        runtime[:queue_size].positive? ||
        runtime[:scheduled_jobs].positive? ||
        runtime[:schedule_marker_ttl]
          .positive?
    end

    def record_recent_batch(batch)
      Sidekiq.redis do |redis|
        redis.lpush(
          RECENT_BATCHES_KEY,
          JSON.generate(batch)
        )

        redis.ltrim(
          RECENT_BATCHES_KEY,
          0,
          RECENT_BATCHES_LIMIT - 1
        )
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_profile_operational_snapshot] " \
        "recent_batch_write_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def recent_batches
      Sidekiq.redis do |redis|
        redis
          .lrange(
            RECENT_BATCHES_KEY,
            0,
            RECENT_BATCHES_LIMIT - 1
          )
          .filter_map do |raw|
            symbolize(
              JSON.parse(raw)
            )
          rescue JSON::ParserError
            nil
          end
      end
    rescue StandardError
      []
    end

    def unavailable_snapshot
      {
        module:
          "actor_profiles_strict",

        source:
          "actor_profiles_operational_snapshot",

        available:
          false,

        generated_at:
          Time.current,

        status:
          "unknown",

        sync: {
          layer1_tip: nil,
          cluster_tip: nil,
          strict_tips_aligned: false,
          profile_max_height: nil
        },

        progress: {
          total_clusters: 0,
          actor_profiles: 0,
          missing_profiles: 0,
          stale_profiles: 0,
          certified_profiles: 0,
          pending_profiles: 0,
          completion_pct: 0.0
        },

        certification: {
          required_profile_version:
            ActorProfiles::
              StrictBuildFromCluster::
              PROFILE_VERSION
        },

        integrity: {
          profile_partition_delta: nil,
          profile_partition_ok: nil
        },

        activity: {
          pipeline_state: "unknown",
          wait_reason: nil
        },

        automation: {
          queue_name: STRICT_QUEUE,
          process_present: false,
          process_count: 0,
          busy_workers: 0,
          queue_size: 0,
          scheduled_jobs: 0,
          retries: 0,
          dead_jobs: 0,
          automation_ok: false
        },

        last_batch: nil,
        recent_batches: [],
        issues: ["operational_cache_missing"]
      }
    end

    def symbolize(value)
      return nil if value.nil?

      if value.respond_to?(
        :deep_symbolize_keys
      )
        value.deep_symbolize_keys
      else
        value
      end
    end
  end
end
