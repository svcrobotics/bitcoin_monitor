# frozen_string_literal: true

require "json"

module ActorProfiles
  class BatchProgress
    KEY =
      "actor_profiles:strict_batch:progress:v1"

    TTL_SECONDS = 7_200

    class << self
      def start!(token:, requested_limit:)
        return false if token.blank?

        write(
          token: token,
          status: "running",
          started_at: timestamp,
          updated_at: timestamp,
          requested_limit: requested_limit.to_i,
          selected: 0,
          processed: 0,
          built: 0,
          deferred: 0,
          failed: 0,
          current_cluster_id: nil,
          last_cluster_id: nil,
          last_outcome: nil,
          elapsed_ms: 0
        )
      end

      def update!(token:, **attributes)
        return false if token.blank?

        Sidekiq.redis do |redis|
          raw = redis.get(KEY)
          return false if raw.blank?

          current =
            JSON.parse(raw)

          return false unless
            current["token"].to_s ==
              token.to_s

          payload =
            current.merge(
              attributes.transform_keys(
                &:to_s
              )
            )

          payload["updated_at"] =
            timestamp

          redis.set(
            KEY,
            JSON.generate(payload),
            ex: TTL_SECONDS
          )

          true
        end
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_profile_batch_progress] " \
          "update_failed " \
          "#{error.class}: #{error.message}"
        )

        false
      end

      def read
        raw =
          Sidekiq.redis do |redis|
            redis.get(KEY)
          end

        return nil if raw.blank?

        payload =
          JSON.parse(raw)
            .deep_symbolize_keys

        payload.delete(:token)
        payload
      rescue JSON::ParserError
        nil
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_profile_batch_progress] " \
          "read_failed " \
          "#{error.class}: #{error.message}"
        )

        nil
      end

      def clear!(token: nil)
        Sidekiq.redis do |redis|
          if token.present?
            raw = redis.get(KEY)
            return false if raw.blank?

            current =
              JSON.parse(raw)

            return false unless
              current["token"].to_s ==
                token.to_s
          end

          redis.del(KEY)
          true
        end
      rescue JSON::ParserError
        Sidekiq.redis do |redis|
          redis.del(KEY)
        end

        true
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_profile_batch_progress] " \
          "clear_failed " \
          "#{error.class}: #{error.message}"
        )

        false
      end

      private

      def write(payload)
        Sidekiq.redis do |redis|
          redis.set(
            KEY,
            JSON.generate(payload),
            ex: TTL_SECONDS
          )
        end

        true
      rescue StandardError => error
        Rails.logger.warn(
          "[actor_profile_batch_progress] " \
          "start_failed " \
          "#{error.class}: #{error.message}"
        )

        false
      end

      def timestamp
        Time.current.iso8601(6)
      end
    end
  end
end
