# frozen_string_literal: true

require "json"

module ActorProfiles
  class SlowProfileQuarantine
    KEY_PREFIX =
      "actor_profiles:slow_profile_quarantine:#{Rails.env}"

    RETRY_AT_KEY =
      "#{KEY_PREFIX}:retry_at"

    METADATA_KEY =
      "#{KEY_PREFIX}:metadata"

    DEFAULT_RETRY_DELAYS_SECONDS = [
      30.minutes.to_i,
      1.hour.to_i,
      6.hours.to_i,
      24.hours.to_i
    ].freeze

    class << self
      def quarantine!(
        cluster_id:,
        reason:,
        runtime_ms: nil,
        error_class: nil,
        message: nil,
        now: Time.current
      )
        normalized_id =
          Integer(cluster_id)

        raise ArgumentError, "cluster_id must be positive" unless
          normalized_id.positive?

        record = nil

        Sidekiq.redis do |redis|
          previous =
            parse_metadata(
              redis.hget(
                METADATA_KEY,
                normalized_id.to_s
              )
            )

          attempts =
            previous.fetch(
              "attempts",
              0
            ).to_i + 1

          retry_delay_seconds =
            retry_delay_for(
              attempts
            )

          retry_at =
            now.to_f +
              retry_delay_seconds

          payload = {
            "cluster_id" =>
              normalized_id,

            "reason" =>
              reason.to_s,

            "runtime_ms" =>
              runtime_ms&.to_i,

            "error_class" =>
              error_class&.to_s,

            "message" =>
              message.to_s.first(500),

            "attempts" =>
              attempts,

            "last_attempted_at" =>
              now.iso8601(6),

            "retry_delay_seconds" =>
              retry_delay_seconds,

            "retry_at" =>
              Time.at(retry_at)
                .in_time_zone
                .iso8601(6)
          }

          redis.zadd(
            RETRY_AT_KEY,
            retry_at,
            normalized_id.to_s
          )

          redis.hset(
            METADATA_KEY,
            normalized_id.to_s,
            JSON.generate(payload)
          )

          record =
            payload.deep_symbolize_keys
        end

        record
      end

      def active_cluster_ids(
        now: Time.current
      )
        Sidekiq.redis do |redis|
          redis.call(
            "ZRANGE",
            RETRY_AT_KEY,
            (now.to_f + 0.001).to_s,
            "+inf",
            "BYSCORE"
          ).map(&:to_i)
        end
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_profile_slow_quarantine] " \
          "active_ids_failed " \
          "#{error.class}: #{error.message}"
        )

        []
      end

      def due_cluster_ids(
        limit: 100,
        now: Time.current
      )
        Sidekiq.redis do |redis|
          redis.call(
            "ZRANGE",
            RETRY_AT_KEY,
            "-inf",
            now.to_f.to_s,
            "BYSCORE",
            "LIMIT",
            0,
            [limit.to_i, 1].max
          ).map(&:to_i)
        end
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_profile_slow_quarantine] " \
          "due_ids_failed " \
          "#{error.class}: #{error.message}"
        )

        []
      end

      def metadata_for(cluster_id)
        normalized_id =
          Integer(cluster_id)

        Sidekiq.redis do |redis|
          parse_metadata(
            redis.hget(
              METADATA_KEY,
              normalized_id.to_s
            )
          )
        end
      end

      def clear!(cluster_id)
        normalized_id =
          Integer(cluster_id)

        Sidekiq.redis do |redis|
          redis.zrem(
            RETRY_AT_KEY,
            normalized_id.to_s
          )

          redis.hdel(
            METADATA_KEY,
            normalized_id.to_s
          )
        end

        true
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_profile_slow_quarantine] " \
          "clear_failed " \
          "cluster_id=#{cluster_id} " \
          "#{error.class}: #{error.message}"
        )

        false
      end

      def active_count(now: Time.current)
        active_cluster_ids(
          now: now
        ).size
      end

      def total_count
        Sidekiq.redis do |redis|
          redis.zcard(
            RETRY_AT_KEY
          ).to_i
        end
      rescue StandardError
        0
      end

      def clear_all!
        Sidekiq.redis do |redis|
          redis.del(
            RETRY_AT_KEY,
            METADATA_KEY
          )
        end

        true
      end

      private

      def retry_delays_seconds
        raw =
          ENV.fetch(
            "ACTOR_PROFILE_SLOW_RETRY_DELAYS_SECONDS",
            DEFAULT_RETRY_DELAYS_SECONDS.join(",")
          )

        parsed =
          raw
            .split(",")
            .filter_map do |value|
              Integer(value.strip)
            rescue ArgumentError, TypeError
              nil
            end
            .select(&:positive?)

        parsed.presence ||
          DEFAULT_RETRY_DELAYS_SECONDS
      end

      def retry_delay_for(attempts)
        delays =
          retry_delays_seconds

        index = [
          attempts.to_i - 1,
          delays.length - 1
        ].min

        delays.fetch(
          [index, 0].max
        )
      end

      def parse_metadata(raw)
        return {} if raw.blank?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
