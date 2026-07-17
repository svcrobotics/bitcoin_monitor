# frozen_string_literal: true

module ActorProfiles
  class StrictBatchBuilder
    DEFAULT_LIMIT =
    Integer(
    ENV.fetch(
    "ACTOR_PROFILE_STRICT_BATCH_LIMIT",
    "25"
    )
    )

    DEFAULT_MAX_RUNTIME_SECONDS =
      Float(
        ENV.fetch(
          "ACTOR_PROFILE_STRICT_BATCH_MAX_RUNTIME_SECONDS",
          "90"
        )
      )

    INCLUDE_SINGLETONS_ENV =
    "ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS"


    def self.call(
      limit: DEFAULT_LIMIT,
      progress_token: nil,
      max_runtime_seconds:
        DEFAULT_MAX_RUNTIME_SECONDS
    )
      new(
        limit: limit,
        progress_token: progress_token,
        max_runtime_seconds:
          max_runtime_seconds
      ).call
    end

    def initialize(
      limit:,
      progress_token: nil,
      max_runtime_seconds:
        DEFAULT_MAX_RUNTIME_SECONDS
    )
      @limit =
        [limit.to_i, 1].max

      @progress_token =
        progress_token

      @max_runtime_seconds =
        [
          max_runtime_seconds.to_f,
          0.001
        ].max
    end

    def call
      started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      cluster_tip = current_cluster_tip
      layer1_tip = current_layer1_tip

      raise "Cluster strict tip missing" if cluster_tip.zero?
      raise "Layer1 processed tip missing" if layer1_tip.zero?

      if cluster_tip > layer1_tip
        return deferred_batch_result(
          started_at: started_at,
          cluster_tip: cluster_tip,
          layer1_tip: layer1_tip,
          reason: "cluster_tip_ahead_of_layer1"
        )
      end

      unless ActorProfiles::CertificationEpoch.active?
        return deferred_batch_result(
          started_at: started_at,
          cluster_tip: cluster_tip,
          layer1_tip: layer1_tip,
          reason: "certification_epoch_inactive"
        )
      end

      selection_started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      cluster_ids = next_cluster_ids

      selection_ms =
        elapsed_ms(selection_started_at)

      built = 0
      deferred = 0
      failed = 0

      runtimes = []
      deferred_samples = []
      failures = []
      slow_quarantines = []
      profile_stage_timings = []
      stopped_reason = nil

      build_loop_started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      publish_progress(
        selected: cluster_ids.size,
        processed: 0,
        built: built,
        deferred: deferred,
        failed: failed,
        cluster_tip: cluster_tip,
        layer1_tip: layer1_tip,
        selection_ms: selection_ms,
        elapsed_ms: elapsed_ms(started_at)
      )

      cluster_ids.each_with_index do |cluster_id, index|
        outcome = nil

        if index.positive? &&
           runtime_budget_exhausted?(
             build_loop_started_at
           )
          stopped_reason =
            "runtime_budget_exhausted"

          processed_count =
            built + deferred + failed

          Rails.logger.info(
            "[actor_profile_strict_batch] " \
            "stopped reason=#{stopped_reason} " \
            "processed=#{processed_count} " \
            "selected=#{cluster_ids.size} " \
            "elapsed_ms=#{elapsed_ms(build_loop_started_at)} " \
            "max_runtime_seconds=#{@max_runtime_seconds}"
          )

          publish_progress(
            current_cluster_id: nil,
            processed: processed_count,
            built: built,
            deferred: deferred,
            failed: failed,
            stopped_reason: stopped_reason,
            elapsed_ms: elapsed_ms(started_at)
          )

          break
        end

        publish_progress(
          current_cluster_id: cluster_id,
          processed: index,
          built: built,
          deferred: deferred,
          failed: failed,
          elapsed_ms: elapsed_ms(started_at)
        )

        begin
          result =
            ActorProfiles::StrictBuildFromCluster.call(
              cluster_id: cluster_id
            )

          built += 1
          outcome = "built"

          runtime_ms =
            result[:runtime_ms].to_i

          runtimes << runtime_ms
          profile_stage_timings << {
            cluster_id:
              cluster_id,

            stage_timings_ms:
              result[:stage_timings_ms] || {}
          }

          if runtime_ms >=
             slow_profile_threshold_ms
            quarantine =
              quarantine_slow_profile(
                cluster_id: cluster_id,
                reason: "slow_runtime",
                runtime_ms: runtime_ms
              )

            slow_quarantines <<
              quarantine if quarantine
          else
            clear_slow_profile_quarantine(
              cluster_id
            )
          end

        rescue ActorProfiles::DeferredSnapshotError => error
          deferred += 1
          outcome = "deferred"
          deferred_samples << error.to_h

          if error.reason.to_s ==
             "profile_timeout"
            quarantine =
              quarantine_slow_profile(
                cluster_id: cluster_id,
                reason: "profile_timeout",
                runtime_ms:
                  error.details[:runtime_ms] ||
                  error.details["runtime_ms"],
                error: error
              )

            slow_quarantines <<
              quarantine if quarantine
          end

          Rails.logger.info(
            "[actor_profile_strict_batch] " \
            "deferred cluster_id=#{cluster_id} " \
            "reason=#{error.reason} " \
            "message=#{error.message}"
          )

        rescue ActiveRecord::QueryCanceled => error
          timeout_seconds =
            ActorProfiles::StrictBuildFromCluster::PROFILE_STATEMENT_TIMEOUT_SECONDS

          deferred += 1
          outcome = "deferred"

          quarantine =
            quarantine_slow_profile(
              cluster_id: cluster_id,
              reason: "profile_timeout",
              runtime_ms:
                timeout_seconds * 1000,
              error: error
            )

          slow_quarantines <<
            quarantine if quarantine

          deferred_samples << {
            cluster_id: cluster_id,
            reason: "profile_timeout",
            timeout_seconds: timeout_seconds,
            error_class: error.class.name,
            message: error.message
          }

          Rails.logger.warn(
            "[actor_profile_strict_batch] " \
            "deferred cluster_id=#{cluster_id} " \
            "reason=profile_timeout " \
            "timeout_seconds=#{timeout_seconds} " \
            "#{error.class}: #{error.message}"
          )

        rescue ActiveRecord::SerializationFailure,
               ActiveRecord::Deadlocked => error
          deferred += 1
          outcome = "deferred"

          deferred_samples << {
            cluster_id: cluster_id,
            reason: "database_concurrency",
            error_class: error.class.name,
            message: error.message
          }

          Rails.logger.info(
            "[actor_profile_strict_batch] " \
            "deferred cluster_id=#{cluster_id} " \
            "reason=database_concurrency " \
            "#{error.class}: #{error.message}"
          )

        rescue ActiveRecord::RecordNotUnique => error
          deferred += 1
          outcome = "deferred"

          deferred_samples << {
            cluster_id: cluster_id,
            reason: "profile_concurrency_conflict",
            error_class: error.class.name,
            message: error.message
          }

          Rails.logger.info(
            "[actor_profile_strict_batch] " \
            "deferred cluster_id=#{cluster_id} " \
            "reason=profile_concurrency_conflict " \
            "#{error.class}: #{error.message}"
          )

        rescue RuntimeError => error
          if error.message.include?("ActorProfile source is ahead of strict snapshot")
            deferred += 1
            outcome = "deferred"

            deferred_samples << {
              cluster_id: cluster_id,
              reason: "source_ahead_of_strict_snapshot",
              error_class: error.class.name,
              message: error.message
            }

            Rails.logger.info(
              "[actor_profile_strict_batch] " \
              "deferred cluster_id=#{cluster_id} " \
              "reason=source_ahead_of_strict_snapshot " \
              "#{error.class}: #{error.message}"
            )
          else
            raise
          end

        rescue StandardError => error
          failed += 1
          outcome = "failed"

          quarantine =
            quarantine_slow_profile(
              cluster_id: cluster_id,
              reason: "profile_failure",
              error: error
            )

          slow_quarantines <<
            quarantine if quarantine

          failures << {
            cluster_id: cluster_id,
            error_class: error.class.name,
            message: error.message
          }

          Rails.logger.warn(
            "[actor_profile_strict_batch] " \
            "failed cluster_id=#{cluster_id} " \
            "#{error.class}: #{error.message}"
          )
        ensure
          publish_progress(
            current_cluster_id: nil,
            last_cluster_id: cluster_id,
            last_outcome:
              outcome || "interrupted",
            processed: index + 1,
            built: built,
            deferred: deferred,
            failed: failed,
            elapsed_ms: elapsed_ms(started_at)
          )
        end
      end

      processed_count =
        built + deferred + failed

      remaining_selected =
        [
          cluster_ids.size -
            processed_count,
          0
        ].max

      build_loop_ms =
        elapsed_ms(build_loop_started_at)

      counts_started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      actor_profiles_count =
        ActorProfile.count

      missing_count =
        missing_profiles_count

      stale_count =
        stale_profiles_count

      counts_ms =
        elapsed_ms(counts_started_at)

      duration_ms =
        elapsed_ms(started_at)

      successful_runtime_ms =
        runtimes.sum

      deferred_or_overhead_runtime_ms = [
        build_loop_ms -
          successful_runtime_ms,
        0
      ].max

      unattributed_runtime_ms = [
        duration_ms -
          selection_ms -
          build_loop_ms -
          counts_ms,
        0
      ].max

      {
        ok: failed.zero?,
        status: failed.zero? ? "completed" : "failed",

        requested_limit: @limit,
        selected: cluster_ids.size,
        processed: processed_count,
        remaining_selected:
          remaining_selected,

        stopped_reason:
          stopped_reason,

        max_runtime_seconds:
          @max_runtime_seconds,

        built: built,
        deferred: deferred,
        failed: failed,

        slow_quarantined:
          slow_quarantines.size,

        slow_quarantine_active:
          ActorProfiles::
            SlowProfileQuarantine
            .active_count,

        slow_quarantine_samples:
          slow_quarantines.first(10),

        profile_stage_timings:
          profile_stage_timings.first(10),

        deferred_samples:
          deferred_samples.first(10),

        failures:
          failures.first(10),

        cluster_tip: cluster_tip,
        layer1_tip: layer1_tip,

        actor_profiles_count:
          actor_profiles_count,

        missing_profiles_count:
          missing_count,

        stale_profiles_count:
          stale_count,

        duration_ms:
          duration_ms,

        selection_ms:
          selection_ms,

        build_loop_ms:
          build_loop_ms,

        counts_ms:
          counts_ms,

        successful_runtime_ms:
          successful_runtime_ms,

        deferred_or_overhead_runtime_ms:
          deferred_or_overhead_runtime_ms,

        unattributed_runtime_ms:
          unattributed_runtime_ms,

        avg_runtime_ms:
          if runtimes.empty?
            0
          else
            (
              runtimes.sum.to_f /
              runtimes.size
            ).round(1)
          end,

        min_runtime_ms: runtimes.min,
        max_runtime_ms: runtimes.max
      }
    end

    private

    def publish_progress(**attributes)
      return false if
        @progress_token.blank?

      ActorProfiles::BatchProgress.update!(
        token: @progress_token,
        **attributes
      )
    end

    def deferred_batch_result(
      started_at:,
      cluster_tip:,
      layer1_tip:,
      reason:
    )
      Rails.logger.info(
        "[actor_profile_strict_batch] " \
        "batch_deferred reason=#{reason} " \
        "cluster_tip=#{cluster_tip} " \
        "layer1_tip=#{layer1_tip}"
      )

      {
        ok: true,
        status: "deferred",
        reason: reason,

        requested_limit: @limit,
        selected: 0,
        built: 0,
        deferred: 0,
        failed: 0,

        slow_quarantined: 0,
        slow_quarantine_active:
          ActorProfiles::
            SlowProfileQuarantine
            .active_count,
        slow_quarantine_samples: [],

        deferred_samples: [],
        failures: [],

        cluster_tip: cluster_tip,
        layer1_tip: layer1_tip,

        actor_profiles_count:
          ActorProfile.count,

        missing_profiles_count:
          nil,

        stale_profiles_count:
          nil,

        duration_ms:
          elapsed_ms(started_at),

        avg_runtime_ms: 0,
        min_runtime_ms: nil,
        max_runtime_ms: nil
      }
    end

    def next_cluster_ids
      quarantined_ids =
        ActorProfiles::
          SlowProfileQuarantine
          .active_cluster_ids

      legacy_target =
        @limit >= 5 ? 1 : 0

      urgent_target =
        if @limit >= 2
          [(@limit * 0.30).floor, 1].max
        else
          0
        end

      missing_target =
        @limit -
        urgent_target -
        legacy_target

      urgent_ids =
        select_existing_profile_cluster_ids(
          condition:
            urgent_stale_profile_condition,
          limit:
            urgent_target,
          exclude_ids:
            quarantined_ids
        )

      missing_ids =
        select_missing_cluster_ids(
          limit:
            missing_target,
          exclude_ids:
            quarantined_ids +
              urgent_ids
        )

      legacy_ids =
        select_existing_profile_cluster_ids(
          condition:
            legacy_profile_condition,
          limit:
            legacy_target,
          exclude_ids:
            quarantined_ids +
              urgent_ids +
              missing_ids
        )

      selected =
        (
          urgent_ids +
          missing_ids +
          legacy_ids
        ).uniq

      if selected.size < @limit
        selected +=
          select_missing_cluster_ids(
            limit:
              @limit - selected.size,
            exclude_ids:
              quarantined_ids +
                selected
          )
      end

      if selected.size < @limit
        selected +=
          select_existing_profile_cluster_ids(
            condition:
              urgent_stale_profile_condition,
            limit:
              @limit - selected.size,
            exclude_ids:
              quarantined_ids +
                selected
          )
      end

      if selected.size < @limit
        selected +=
          select_existing_profile_cluster_ids(
            condition:
              legacy_profile_condition,
            limit:
              @limit - selected.size,
            exclude_ids:
              quarantined_ids +
                selected
          )
      end

      selected.uniq.first(@limit)
    end

    def select_missing_cluster_ids(
      limit:,
      exclude_ids: []
    )
      return [] unless limit.to_i.positive?

      sql = <<~SQL.squish
        SELECT clusters.id
        FROM clusters

        LEFT JOIN actor_profiles
          ON actor_profiles.cluster_id =
             clusters.id

        WHERE actor_profiles.id IS NULL
          AND #{certification_target_condition}

          #{excluded_ids_condition(
            "clusters.id",
            exclude_ids
          )}

        ORDER BY
          clusters.last_seen_height
            DESC NULLS LAST,
          clusters.id DESC

        LIMIT #{limit.to_i}
      SQL

      ActiveRecord::Base
        .connection
        .select_values(sql)
        .map(&:to_i)
    end

    def select_existing_profile_cluster_ids(
      condition:,
      limit:,
      exclude_ids: []
    )
      return [] unless limit.to_i.positive?

      sql = <<~SQL.squish
        SELECT clusters.id
        FROM clusters

        INNER JOIN actor_profiles
          ON actor_profiles.cluster_id =
             clusters.id

        WHERE #{certification_target_condition}

          AND (
            #{condition}
          )

          #{excluded_ids_condition(
            "clusters.id",
            exclude_ids
          )}

        ORDER BY
          clusters.last_seen_height
            DESC NULLS LAST,
          clusters.id DESC

        LIMIT #{limit.to_i}
      SQL

      ActiveRecord::Base
        .connection
        .select_values(sql)
        .map(&:to_i)
    end

    def excluded_ids_condition(
      column,
      ids
    )
      normalized =
        Array(ids)
          .map(&:to_i)
          .select(&:positive?)
          .uniq

      return "" if normalized.empty?

      "AND #{column} NOT IN (" \
        "#{normalized.join(',')}" \
        ")"
    end

    def missing_profiles_count
      sql = <<~SQL.squish
        SELECT COUNT(*)
        FROM clusters

        LEFT JOIN actor_profiles
          ON actor_profiles.cluster_id = clusters.id

        WHERE actor_profiles.id IS NULL
          AND #{certification_target_condition}
      SQL

      ActiveRecord::Base
        .connection
        .select_value(sql)
        .to_i
    end

    def stale_profiles_count
      sql = <<~SQL.squish
        SELECT COUNT(*)
        FROM actor_profiles

        INNER JOIN clusters
          ON clusters.id = actor_profiles.cluster_id

        WHERE #{certification_target_condition}

          AND (
            #{stale_profile_condition}
          )
      SQL

      ActiveRecord::Base
        .connection
        .select_value(sql)
        .to_i
    end

    def eligible_cluster_condition
      if include_singletons?
        "clusters.address_count > 0"
      else
        "clusters.address_count > 1"
      end
    end

    def certification_target_condition
      @certification_target_condition ||=
        ActorProfiles::
          CertificationTargetScope::
          sql_condition(
            checkpoint_height:
              current_cluster_tip
          )
    end

    def current_epoch
      @current_epoch ||=
        ActorProfiles::
          CertificationEpoch::
          current ||
        raise(
          ActorProfiles::
            CertificationTargetScope::
            InactiveEpoch,
          "ActorProfile certification epoch is inactive"
        )
    end

    def epoch_certification_mismatch_condition
      scope =
        ActiveRecord::Base
          .connection
          .quote(
            ActorProfile::
              CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH
          )

      <<~SQL.squish
        actor_profiles.certification_epoch_height
          IS DISTINCT FROM
          #{current_epoch.start_height.to_i}

        OR COALESCE(
          actor_profiles.certification_scope,
          ''
        ) <> #{scope}

        OR actor_profiles.certified_at IS NULL
      SQL
    end

    def urgent_stale_profile_condition
      <<~SQL.squish
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

        OR (
          #{epoch_certification_mismatch_condition}
        )
      SQL
    end

    def legacy_profile_condition
      <<~SQL.squish
        (
          COALESCE(
            actor_profiles.traits
              ->> 'profile_version',
            ''
          ) <> '#{ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION}'

          OR COALESCE(
            actor_profiles.metadata
              ->> 'strict',
            'false'
          ) <> 'true'
        )

        AND NOT (
          #{urgent_stale_profile_condition}
        )
      SQL
    end

    def stale_profile_condition
      <<~SQL.squish
        (
          #{urgent_stale_profile_condition}
        )

        OR COALESCE(
          actor_profiles.traits ->> 'profile_version',
          ''
        ) <> '#{ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION}'

        OR COALESCE(
          actor_profiles.metadata ->> 'strict',
          'false'
        ) <> 'true'
      SQL
    end

    def include_singletons?
      ActiveModel::Type::Boolean
        .new
        .cast(
          ENV.fetch(
            INCLUDE_SINGLETONS_ENV,
            "false"
          )
        )
    end

    def current_layer1_tip
      @current_layer1_tip ||=
        if defined?(BlockBufferModel)
          BlockBufferModel
            .where(status: "processed")
            .maximum(:height)
            .to_i
        else
          0
        end
    end

    def current_cluster_tip
      @current_cluster_tip ||=
        if defined?(ClusterProcessedBlock)
          ClusterProcessedBlock
            .where(status: "processed")
            .maximum(:height)
            .to_i
        else
          0
        end
    end

    def slow_profile_threshold_ms
      seconds =
        Float(
          ENV.fetch(
            "ACTOR_PROFILE_STRICT_SLOW_THRESHOLD_SECONDS",
            "30"
          )
        )

      (
        [seconds, 1.0].max *
          1000
      ).round
    rescue ArgumentError, TypeError
      30_000
    end

    def quarantine_slow_profile(
      cluster_id:,
      reason:,
      runtime_ms: nil,
      error: nil
    )
      ActorProfiles::
        SlowProfileQuarantine
        .quarantine!(
          cluster_id: cluster_id,
          reason: reason,
          runtime_ms: runtime_ms,
          error_class:
            error&.class&.name,
          message:
            error&.message
        )
    rescue StandardError => quarantine_error
      Rails.logger.warn(
        "[actor_profile_strict_batch] " \
        "slow_quarantine_failed " \
        "cluster_id=#{cluster_id} " \
        "#{quarantine_error.class}: " \
        "#{quarantine_error.message}"
      )

      nil
    end

    def clear_slow_profile_quarantine(
      cluster_id
    )
      ActorProfiles::
        SlowProfileQuarantine
        .clear!(
          cluster_id
        )
    end

    def runtime_budget_exhausted?(
      started_at
    )
      elapsed_ms(started_at) >=
        (
          @max_runtime_seconds *
            1000
        ).to_i
    end

    def elapsed_ms(started_at)
      (
        (
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) - started_at
        ) * 1000
      ).round
    end

  end
end
