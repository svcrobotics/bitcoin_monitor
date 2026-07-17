# frozen_string_literal: true

require "json"
require "time"
require "sidekiq"

module ActorBehaviors
  module Heavy
    class ControlSnapshot
      AUTO_ENABLED_ENV =
        "ACTOR_BEHAVIOR_HEAVY_AUTO_ENABLED"

      LABELS_ENABLED_ENV =
        "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED"

      INTERVAL_ENV =
        "ACTOR_BEHAVIOR_HEAVY_AUTO_INTERVAL_SECONDS"

      DEFAULT_INTERVAL_SECONDS =
        1_800

      MINIMUM_INTERVAL_SECONDS =
        300

      MAXIMUM_INTERVAL_SECONDS =
        86_400

      SCHEDULER_RUNTIME_KEY =
        "strict_pipeline:scheduler:runtime_status"

      SCHEDULER_RUNTIME_MAX_AGE_SECONDS =
        180

      LAST_ENQUEUED_KEY =
        "actor_behaviors:heavy:auto:last_enqueued_at"

      def self.call(
        current_snapshot: nil,
        minimum_height_delta:
          CandidateScope::
            DEFAULT_MINIMUM_HEIGHT_DELTA
      )
        new(
          current_snapshot:
            current_snapshot,

          minimum_height_delta:
            minimum_height_delta
        ).call
      end

      def self.interval_seconds
        Integer(
          ENV.fetch(
            INTERVAL_ENV,
            DEFAULT_INTERVAL_SECONDS.to_s
          )
        ).clamp(
          MINIMUM_INTERVAL_SECONDS,
          MAXIMUM_INTERVAL_SECONDS
        )
      rescue ArgumentError, TypeError
        DEFAULT_INTERVAL_SECONDS
      end

      def self.mark_enqueued!(
        at: Time.current
      )
        Sidekiq.redis do |redis|
          redis.set(
            LAST_ENQUEUED_KEY,
            at.iso8601(6),
            ex: [
              interval_seconds * 4,
              3_600
            ].max
          )
        end

        true
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_behavior_heavy_control] " \
          "mark_enqueued_failed " \
          "#{error.class}: #{error.message}"
        )

        false
      end

      def initialize(
        current_snapshot:,
        minimum_height_delta:
      )
        @current_snapshot =
          current_snapshot || {}

        @minimum_height_delta =
          [
            minimum_height_delta.to_i,
            1
          ].max
      end

      def call
        runtime =
          scheduler_runtime

        local_auto_enabled =
          boolean_env(
            AUTO_ENABLED_ENV
          )

        local_labels_enabled =
          boolean_env(
            LABELS_ENABLED_ENV
          )

        scheduler_auto_enabled =
          runtime_fresh?(runtime) &&
          runtime[
            "actor_behavior_heavy_auto_enabled"
          ] == true

        scheduler_labels_enabled =
          runtime_fresh?(runtime) &&
          runtime[
            "actor_behavior_heavy_labels_enabled"
          ] == true

        auto_enabled =
          local_auto_enabled ||
          scheduler_auto_enabled

        labels_enabled =
          local_labels_enabled ||
          scheduler_labels_enabled

        cooldown =
          cooldown_snapshot

        to_height =
          resolve_to_height

        candidate =
          if auto_enabled &&
             labels_enabled &&
             !cooldown[:active] &&
             to_height.positive?
            CandidateScope.call(
              limit: 1,

              to_height:
                to_height,

              minimum_height_delta:
                minimum_height_delta
            ).first
          end

        {
          status:
            "active",

          hypothesis:
            CandidateScope::HYPOTHESIS,

          scope_version:
            CandidateScope::VERSION,

          auto_enabled:
            auto_enabled,

          local_auto_enabled:
            local_auto_enabled,

          scheduler_auto_enabled:
            scheduler_auto_enabled,

          labels_enabled:
            labels_enabled,

          local_labels_enabled:
            local_labels_enabled,

          scheduler_labels_enabled:
            scheduler_labels_enabled,

          scheduler_runtime_fresh:
            runtime_fresh?(runtime),

          scheduler_runtime:
            runtime,

          interval_seconds:
            self.class.interval_seconds,

          cooldown_active:
            cooldown[:active],

          cooldown_remaining_seconds:
            cooldown[:remaining_seconds],

          last_enqueued_at:
            cooldown[:last_enqueued_at],

          to_height:
            to_height,

          minimum_height_delta:
            minimum_height_delta,

          work_available:
            candidate.present?,

          candidate_snapshot_id:
            candidate&.id,

          candidate_cluster_id:
            candidate&.cluster_id,

          generated_at:
            Time.current
        }
      rescue StandardError => error
        {
          status:
            "unavailable",

          auto_enabled:
            false,

          labels_enabled:
            false,

          work_available:
            false,

          cooldown_active:
            false,

          error_class:
            error.class.name,

          error_message:
            error.message,

          generated_at:
            Time.current
        }
      end

      private

      attr_reader(
        :current_snapshot,
        :minimum_height_delta
      )

      def boolean_env(name)
        ActiveModel::Type::Boolean
          .new
          .cast(
            ENV.fetch(
              name,
              "false"
            )
          ) == true
      end

      def resolve_to_height
        snapshot_height =
          current_snapshot.dig(
            :layer1,
            :processed_height
          ).to_i

        return snapshot_height if
          snapshot_height.positive?

        BlockBufferModel
          .where(
            status:
              "processed"
          )
          .maximum(
            :height
          )
          .to_i
      end

      def scheduler_runtime
        raw =
          Sidekiq.redis do |redis|
            redis.get(
              SCHEDULER_RUNTIME_KEY
            )
          end

        return {} if raw.blank?

        JSON.parse(raw)
      rescue JSON::ParserError,
             StandardError
        {}
      end

      def runtime_fresh?(runtime)
        observed_at =
          runtime[
            "observed_at"
          ]

        return false if
          observed_at.blank?

        observed_time =
          Time.iso8601(
            observed_at
          )

        (
          Time.current -
          observed_time
        ).abs <=
          SCHEDULER_RUNTIME_MAX_AGE_SECONDS
      rescue ArgumentError,
             TypeError
        false
      end

      def cooldown_snapshot
        raw =
          Sidekiq.redis do |redis|
            redis.get(
              LAST_ENQUEUED_KEY
            )
          end

        return {
          active: false,
          remaining_seconds: 0,
          last_enqueued_at: nil
        } if raw.blank?

        last_enqueued_at =
          Time.iso8601(raw)

        elapsed =
          Time.current -
          last_enqueued_at

        remaining =
          [
            self.class.interval_seconds -
              elapsed,
            0
          ].max.ceil

        {
          active:
            remaining.positive?,

          remaining_seconds:
            remaining,

          last_enqueued_at:
            last_enqueued_at
        }
      rescue ArgumentError,
             TypeError,
             StandardError
        {
          active: false,
          remaining_seconds: 0,
          last_enqueued_at: nil
        }
      end
    end
  end
end
