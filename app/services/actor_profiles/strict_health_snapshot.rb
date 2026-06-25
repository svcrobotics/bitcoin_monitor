# frozen_string_literal: true

require "sidekiq/api"
require "json"

module ActorProfiles
  class StrictHealthSnapshot
    QUEUE_NAME = "actor_profile_strict"
    JOB_CLASS = "ActorProfiles::StrictBatchJob"
    PROFILE_VERSION = "strict_v3_core"

    def self.call
      new.call
    end

    def call
      now = Time.current

      layer1_tip = current_layer1_tip
      cluster_tip = current_cluster_tip

      total_clusters =
        clusters_scope.count

      actor_profiles_count =
        ActorProfile.count

      profiles_in_scope =
        profiles_in_scope_count

      missing_profiles =
        missing_profiles_count

      dirty_profiles =
        profiles_where_count(
          "actor_profiles.dirty IS TRUE"
        )

      composition_mismatches =
        profiles_where_count(
          "actor_profiles.cluster_composition_version " \
          "IS DISTINCT FROM clusters.composition_version"
        )

      height_stale_profiles =
        profiles_where_count(
          "COALESCE(actor_profiles.last_computed_height, 0) " \
          "< COALESCE(clusters.last_seen_height, 0)"
        )

      provenance_mismatches =
        profiles_where_count(
          provenance_mismatch_condition
        )

      stale_profiles =
        profiles_where_count(
          stale_condition
        )

      certified_profiles =
        profiles_where_count(
          certified_condition
        )

      strict_core_profiles =
        profiles_where_count(
          "actor_profiles.traits ->> 'profile_version' = " \
          "#{quoted(PROFILE_VERSION)}"
        )

      invalid_profile_refs =
        invalid_profile_refs_count

      partition_delta =
        total_clusters -
        (
          missing_profiles +
          stale_profiles +
          certified_profiles
        )

      profile_max_height =
        ActorProfile
          .maximum(:last_computed_height)
          .to_i

      certified_profile_max_height =
        certified_profile_max_height_value

      current_height_profiles =
        if cluster_tip.positive?
          profiles_where_count(
            "#{certified_condition} " \
            "AND actor_profiles.last_computed_height = " \
            "#{cluster_tip}"
          )
        else
          0
        end

      queue_size =
        sidekiq_queue_size

      scheduled_jobs =
        scheduled_job_count

      active_workers =
        active_worker_count

      automation_ok =
        scheduled_jobs.positive? ||
        queue_size.positive? ||
        active_workers.positive?

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

      last_profile_at =
        ActorProfile.maximum(:updated_at)

      strict_tips_aligned =
        layer1_tip.positive? &&
        cluster_tip.positive? &&
        layer1_tip == cluster_tip

      issues = []

      issues << "layer1_tip_missing" if layer1_tip.zero?
      issues << "cluster_tip_missing" if cluster_tip.zero?
      issues << "no_clusters" if total_clusters.zero?

      unless strict_tips_aligned
        issues <<
          "strict_tips_not_aligned=" \
          "#{cluster_tip}/#{layer1_tip}"
      end

      if invalid_profile_refs.positive?
        issues <<
          "invalid_profile_refs=" \
          "#{invalid_profile_refs}"
      end

      unless partition_delta.zero?
        issues <<
          "profile_partition_delta=" \
          "#{partition_delta}"
      end

      if !automation_ok &&
         pending_profiles.positive?
        issues << "automation_missing"
      end

      if queue_size > 1_000
        issues <<
          "queue_high=#{queue_size}"
      end

      critical_issue =
        layer1_tip.zero? ||
        cluster_tip.zero? ||
        total_clusters.zero? ||
        invalid_profile_refs.positive? ||
        !partition_delta.zero?

      status =
        if critical_issue
          "critical"

        elsif !automation_ok &&
              pending_profiles.positive?
          "warning"

        elsif queue_size > 1_000
          "warning"

        elsif pending_profiles.positive? ||
              !strict_tips_aligned
          "syncing"

        else
          "healthy"
        end

      verdict =
        case status
        when "healthy"
          "ActorProfile est certifié : tous les clusters " \
          "disposent d’un profil strict_v3_core calculé sur " \
          "leur composition actuelle."

        when "syncing"
          "ActorProfile reconstruit progressivement les profils " \
          "depuis les clusters certifiés et enregistre la version " \
          "exacte de leur composition."

        when "warning"
          "Des profils restent à construire ou à reconstruire, " \
          "mais aucune automatisation ActorProfile active ou " \
          "planifiée n’est actuellement observée."

        else
          "ActorProfile présente une anomalie d’intégrité ou une " \
          "source stricte indisponible. Une vérification est nécessaire."
        end

      {
        module: "actor_profiles_strict",
        source:
          "actor_profiles_strict_health_snapshot",
        generated_at: now,

        status: status,
        verdict: verdict,

        sync: {
          layer1_tip: layer1_tip,
          cluster_tip: cluster_tip,
          strict_tips_aligned:
            strict_tips_aligned,

          profile_max_height:
            profile_max_height,

          certified_profile_max_height:
            certified_profile_max_height,

          current_height_profiles:
            current_height_profiles
        },

        progress: {
          total_clusters:
            total_clusters,

          profiles_in_scope:
            profiles_in_scope,

          actor_profiles:
            actor_profiles_count,

          missing_profiles:
            missing_profiles,

          stale_profiles:
            stale_profiles,

          certified_profiles:
            certified_profiles,

          pending_profiles:
            pending_profiles,

          completion_pct:
            completion_pct
        },

        certification: {
          required_profile_version:
            PROFILE_VERSION,

          strict_core_profiles:
            strict_core_profiles,

          certified_profiles:
            certified_profiles,

          dirty_profiles:
            dirty_profiles,

          composition_mismatches:
            composition_mismatches,

          height_stale_profiles:
            height_stale_profiles,

          provenance_mismatches:
            provenance_mismatches
        },

        automation: {
          queue_name:
            QUEUE_NAME,

          queue_size:
            queue_size,

          scheduled_jobs:
            scheduled_jobs,

          active_workers:
            active_workers,

          automation_ok:
            automation_ok
        },

        integrity: {
          invalid_profile_refs:
            invalid_profile_refs,

          profile_partition_delta:
            partition_delta,

          profile_partition_ok:
            partition_delta.zero?
        },

        freshness: {
          last_profile_at:
            last_profile_at,

          profiles_last_10m:
            ActorProfile
              .where(
                "updated_at >= ?",
                10.minutes.ago
              )
              .count,

          profiles_last_1h:
            ActorProfile
              .where(
                "updated_at >= ?",
                1.hour.ago
              )
              .count
        },

        totals: {
          clusters:
            Cluster.count,

          clusters_with_addresses:
            total_clusters,

          actor_profiles:
            actor_profiles_count
        },

        issues: issues
      }
    end

    private

    def clusters_scope
      Cluster.where(address_exists_condition)
    end

    def profiles_in_scope_count
      sql = <<~SQL.squish
        SELECT COUNT(*)
        FROM actor_profiles

        INNER JOIN clusters
          ON clusters.id =
             actor_profiles.cluster_id

        WHERE #{address_exists_condition}
      SQL

      select_count(sql)
    end

    def missing_profiles_count
      sql = <<~SQL.squish
        SELECT COUNT(*)
        FROM clusters

        LEFT JOIN actor_profiles
          ON actor_profiles.cluster_id =
             clusters.id

        WHERE actor_profiles.id IS NULL
          AND #{address_exists_condition}
      SQL

      select_count(sql)
    end

    def profiles_where_count(condition)
      sql = <<~SQL.squish
        SELECT COUNT(*)
        FROM actor_profiles

        INNER JOIN clusters
          ON clusters.id =
             actor_profiles.cluster_id

        WHERE #{address_exists_condition}
          AND (
            #{condition}
          )
      SQL

      select_count(sql)
    end

    def certified_condition
      <<~SQL.squish
        actor_profiles.dirty IS NOT TRUE

        AND actor_profiles.cluster_composition_version =
            clusters.composition_version

        AND COALESCE(
          actor_profiles.last_computed_height,
          0
        ) >= COALESCE(
          clusters.last_seen_height,
          0
        )

        AND actor_profiles.traits ->> 'profile_version' =
            #{quoted(PROFILE_VERSION)}

        AND COALESCE(
          actor_profiles.metadata ->> 'strict',
          'false'
        ) = 'true'
      SQL
    end

    def stale_condition
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
          #{provenance_mismatch_condition}
        )
      SQL
    end

    def provenance_mismatch_condition
      <<~SQL.squish
        COALESCE(
          actor_profiles.traits ->> 'profile_version',
          ''
        ) <> #{quoted(PROFILE_VERSION)}

        OR COALESCE(
          actor_profiles.metadata ->> 'strict',
          'false'
        ) <> 'true'
      SQL
    end

    def invalid_profile_refs_count
      sql = <<~SQL.squish
        SELECT COUNT(*)
        FROM actor_profiles

        LEFT JOIN clusters
          ON clusters.id =
             actor_profiles.cluster_id

        WHERE clusters.id IS NULL
      SQL

      select_count(sql)
    end

    def address_exists_condition
      <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM addresses
          WHERE addresses.cluster_id = clusters.id
        )
      SQL
    end

    def certified_profile_max_height_value
      sql = <<~SQL.squish
        SELECT COALESCE(
          MAX(
            actor_profiles.last_computed_height
          ),
          0
        )
        FROM actor_profiles

        INNER JOIN clusters
          ON clusters.id =
             actor_profiles.cluster_id

        WHERE #{address_exists_condition}
          AND (
            #{certified_condition}
          )
      SQL

      ActiveRecord::Base
        .connection
        .select_value(sql)
        .to_i
    end

    def select_count(sql)
      ActiveRecord::Base
        .connection
        .select_value(sql)
        .to_i
    end

    def quoted(value)
      ActiveRecord::Base
        .connection
        .quote(value)
    end

    def current_layer1_tip
      return 0 unless defined?(
        BlockBufferModel
      )

      BlockBufferModel
        .where(status: "processed")
        .maximum(:height)
        .to_i
    end

    def current_cluster_tip
      return 0 unless defined?(
        ClusterProcessedBlock
      )

      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
        .to_i
    end

    def sidekiq_queue_size
      Sidekiq::Queue
        .new(QUEUE_NAME)
        .count do |job|
          payload_matches?(
            job.item
          )
        end
    rescue StandardError
      0
    end

    def scheduled_job_count
      Sidekiq::ScheduledSet
        .new
        .count do |job|
          payload_matches?(
            job.item
          )
        end
    rescue StandardError
      0
    end

    def active_worker_count
      Sidekiq::WorkSet
        .new
        .count do |_process_id, _thread_id, work|

          queue =
            if work.respond_to?(:queue)
              work.queue
            else
              work.to_h["queue"]
            end

          payload =
            if work.respond_to?(:payload)
              work.payload
            else
              work.to_h["payload"]
            end

          queue.to_s == QUEUE_NAME &&
            payload_matches?(payload)
        end
    rescue StandardError
      0
    end

    def payload_matches?(payload)
      payload =
        JSON.parse(payload) if payload.is_a?(
          String
        )

      payload ||= {}

      return true if
        payload["class"].to_s ==
          JOB_CLASS

      return true if
        payload["wrapped"].to_s ==
          JOB_CLASS

      active_job_payload =
        Array(
          payload["args"]
        ).first

      active_job_payload.is_a?(Hash) &&
        active_job_payload[
          "job_class"
        ].to_s == JOB_CLASS
    rescue JSON::ParserError
      false
    end


  end
end
