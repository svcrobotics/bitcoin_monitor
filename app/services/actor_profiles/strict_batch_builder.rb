# frozen_string_literal: true

module ActorProfiles
  class StrictBatchBuilder
    DEFAULT_LIMIT =
    Integer(
    ENV.fetch(
    "ACTOR_PROFILE_STRICT_BATCH_LIMIT",
    "100"
    )
    )

    INCLUDE_SINGLETONS_ENV =
    "ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS"


    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = [limit.to_i, 1].max
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

      unless cluster_tip == layer1_tip
        return deferred_batch_result(
          started_at: started_at,
          cluster_tip: cluster_tip,
          layer1_tip: layer1_tip,
          reason: "strict_tips_not_aligned"
        )
      end

      cluster_ids = next_cluster_ids

      built = 0
      deferred = 0
      failed = 0

      runtimes = []
      deferred_samples = []
      failures = []

      cluster_ids.each do |cluster_id|
        begin
          result =
            ActorProfiles::StrictBuildFromCluster.call(
              cluster_id: cluster_id
            )

          built += 1
          runtimes << result[:runtime_ms].to_i

        rescue ActorProfiles::DeferredSnapshotError => error
          deferred += 1
          deferred_samples << error.to_h

          Rails.logger.info(
            "[actor_profile_strict_batch] " \
            "deferred cluster_id=#{cluster_id} " \
            "reason=#{error.reason} " \
            "message=#{error.message}"
          )

        rescue ActiveRecord::SerializationFailure,
               ActiveRecord::Deadlocked => error
          deferred += 1

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

        rescue StandardError => error
          failed += 1

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
        end
      end

      {
        ok: failed.zero?,
        status: failed.zero? ? "completed" : "failed",

        requested_limit: @limit,
        selected: cluster_ids.size,

        built: built,
        deferred: deferred,
        failed: failed,

        deferred_samples:
          deferred_samples.first(10),

        failures:
          failures.first(10),

        cluster_tip: cluster_tip,
        layer1_tip: layer1_tip,

        actor_profiles_count:
          ActorProfile.count,

        missing_profiles_count:
          missing_profiles_count,

        stale_profiles_count:
          stale_profiles_count,

        duration_ms:
          elapsed_ms(started_at),

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
      stale_sql = <<~SQL.squish
        SELECT clusters.id
        FROM clusters

        INNER JOIN actor_profiles
          ON actor_profiles.cluster_id = clusters.id

        WHERE #{eligible_cluster_condition}
          AND COALESCE(
            clusters.last_seen_height,
            0
          ) <= #{current_cluster_tip}

          AND (
            #{stale_profile_condition}
          )

        ORDER BY
          clusters.last_seen_height DESC NULLS LAST,
          clusters.id DESC

        LIMIT #{@limit}
      SQL

      stale_ids =
        ActiveRecord::Base
          .connection
          .select_values(stale_sql)
          .map(&:to_i)

      return stale_ids if stale_ids.size >= @limit

      remaining =
        @limit - stale_ids.size

      missing_sql = <<~SQL.squish
        SELECT clusters.id
        FROM clusters

        LEFT JOIN actor_profiles
          ON actor_profiles.cluster_id = clusters.id

        WHERE actor_profiles.id IS NULL
          AND #{eligible_cluster_condition}
          AND COALESCE(
            clusters.last_seen_height,
            0
          ) <= #{current_cluster_tip}

        ORDER BY
          clusters.last_seen_height DESC NULLS LAST,
          clusters.id DESC

        LIMIT #{remaining}
      SQL

      missing_ids =
        ActiveRecord::Base
          .connection
          .select_values(missing_sql)
          .map(&:to_i)

      (stale_ids + missing_ids).uniq
    end

    def missing_profiles_count
      sql = <<~SQL.squish
        SELECT COUNT(*)
        FROM clusters

        LEFT JOIN actor_profiles
          ON actor_profiles.cluster_id = clusters.id

        WHERE actor_profiles.id IS NULL
          AND #{eligible_cluster_condition}
          AND COALESCE(
            clusters.last_seen_height,
            0
          ) <= #{current_cluster_tip}
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

        WHERE #{eligible_cluster_condition}
          AND COALESCE(
            clusters.last_seen_height,
            0
          ) <= #{current_cluster_tip}

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

    def stale_profile_condition
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
