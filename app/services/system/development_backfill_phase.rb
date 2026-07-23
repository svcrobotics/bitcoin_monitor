# frozen_string_literal: true

require "json"

module System
  class DevelopmentBackfillPhase
    STATE_KEY =
      "tansa:pipeline:development_backfill:phase"

    PIPELINE_MODE_ENV =
      "TANSA_PIPELINE_MODE"

    ENABLED_ENV =
      "TANSA_BACKFILL_ALTERNATING_ENABLED"

    START_LAG_ENV =
      "TANSA_BACKFILL_LAYER1_START_LAG"

    STOP_LAG_ENV =
      "TANSA_BACKFILL_LAYER1_STOP_LAG"

    MAX_LAYER1_PHASE_SECONDS_ENV =
      "TANSA_BACKFILL_LAYER1_MAX_PHASE_SECONDS"

    DEVELOPMENT_BACKFILL_MODE =
      "development_backfill"

    DEFAULT_START_LAG = 10
    DEFAULT_STOP_LAG = 2
    DEFAULT_MAX_LAYER1_PHASE_SECONDS = 900

    PHASES = %w[
      downstream_catchup
      layer1_catchup
    ].freeze

    class << self
      def resolve(layer1_lag:, redis: default_redis, now: Time.current)
        config = configuration

        return disabled_payload(config) unless config[:enabled]

        stored = load_state(redis)

        if layer1_lag.nil?
          return config.merge(
            phase: valid_phase(stored["phase"]),
            changed_at: stored["changed_at"],
            entered_layer1_lag:
              stored["entered_layer1_lag"],
            reason: "layer1_lag_unavailable",
            observed_layer1_lag: nil
          )
        end

        lag = [layer1_lag.to_i, 0].max
        current_phase = valid_phase(stored["phase"])
        elapsed_seconds =
          phase_elapsed_seconds(
            stored["changed_at"],
            now: now
          )
        resolved_phase =
          next_phase(
            layer1_lag: lag
          )

        changed =
          current_phase.to_s !=
            resolved_phase.to_s

        now_iso = now.iso8601(6)

        payload =
          config.merge(
            phase: resolved_phase,
            changed_at:
              changed ?
                now_iso :
                stored["changed_at"] || now_iso,
            entered_layer1_lag:
              changed ?
                lag :
                stored["entered_layer1_lag"] || lag,
            reason:
              transition_reason(
                current_phase: current_phase,
                resolved_phase: resolved_phase,
                changed: changed
              ),
            observed_layer1_lag: lag,
            phase_elapsed_seconds:
              changed ? 0 : elapsed_seconds
          )

        redis.set(
          STATE_KEY,
          JSON.generate(payload)
        )

        log_transition(
          current_phase: current_phase,
          resolved_phase: resolved_phase,
          layer1_lag: lag
        ) if changed

        payload
      rescue StandardError => error
        Rails.logger.warn(
          "[development_backfill_phase] " \
          "resolve_failed #{error.class}: #{error.message}"
        )

        configuration.merge(
          phase: nil,
          changed_at: nil,
          entered_layer1_lag: nil,
          reason: "phase_resolution_failed",
          observed_layer1_lag: layer1_lag,
          error: "#{error.class}: #{error.message}"
        )
      end

      def configuration
        requested =
          truthy?(
            ENV.fetch(
              ENABLED_ENV,
              "false"
            )
          )

        start_lag =
          integer_env(
            START_LAG_ENV,
            DEFAULT_START_LAG
          )

        stop_lag =
          integer_env(
            STOP_LAG_ENV,
            DEFAULT_STOP_LAG
          )

        max_layer1_phase_seconds =
          integer_env(
            MAX_LAYER1_PHASE_SECONDS_ENV,
            DEFAULT_MAX_LAYER1_PHASE_SECONDS
          )

        config_valid =
          !start_lag.nil? &&
          !stop_lag.nil? &&
          !max_layer1_phase_seconds.nil? &&
          stop_lag >= 0 &&
          start_lag > stop_lag &&
          max_layer1_phase_seconds.positive?

        mode =
          ENV.fetch(
            PIPELINE_MODE_ENV,
            "realtime"
          ).to_s

        {
          requested: requested,
          enabled:
            requested &&
            mode == DEVELOPMENT_BACKFILL_MODE &&
            config_valid,
          config_valid: config_valid,
          pipeline_mode: mode,
          start_lag: start_lag,
          stop_lag: stop_lag,
          max_layer1_phase_seconds:
            max_layer1_phase_seconds
        }
      end

      # Layer1 owns the strict pipeline for every missing Bitcoin block.
      # The legacy start/stop thresholds remain configuration telemetry only;
      # they no longer create an intentional lag window.
      def next_phase(layer1_lag:)
        layer1_lag.to_i.positive? ?
          "layer1_catchup" :
          "downstream_catchup"
      end

      private

      def disabled_payload(config)
        config.merge(
          phase: nil,
          changed_at: nil,
          entered_layer1_lag: nil,
          reason:
            if config[:requested] &&
               config[:config_valid] != true
              "invalid_configuration"
            elsif config[:requested]
              "not_development_backfill_mode"
            else
              "alternating_backfill_disabled"
            end,
          observed_layer1_lag: nil
        )
      end

      def default_redis
        Redis.new(
          url: ENV.fetch(
            "REDIS_URL",
            "redis://127.0.0.1:6379/0"
          )
        )
      end

      def load_state(redis)
        raw = redis.get(STATE_KEY)

        return {} if raw.blank?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      def integer_env(name, default)
        Integer(
          ENV.fetch(
            name,
            default.to_s
          )
        )
      rescue ArgumentError, TypeError
        nil
      end

      def truthy?(value)
        %w[
          1
          true
          yes
          on
        ].include?(
          value.to_s.downcase
        )
      end

      def valid_phase(value)
        phase = value.to_s

        PHASES.include?(phase) ? phase : nil
      end

      def transition_reason(
        current_phase:,
        resolved_phase:,
        changed:
      )
        unless changed
          return resolved_phase == "layer1_catchup" ?
            "layer1_continuous_catchup" :
            "layer1_caught_up"
        end

        return "initial_phase" if current_phase.blank?

        if resolved_phase == "layer1_catchup"
          "layer1_lag_detected"
        else
          "layer1_caught_up"
        end
      end

      def phase_elapsed_seconds(changed_at, now:)
        parsed =
          Time.zone.parse(changed_at.to_s)

        return 0 unless parsed

        [
          now - parsed,
          0
        ].max.to_i
      rescue ArgumentError, TypeError
        0
      end

      def log_transition(
        current_phase:,
        resolved_phase:,
        layer1_lag:
      )
        Rails.logger.info(
          "[development_backfill_phase] " \
          "transition " \
          "#{current_phase.presence || 'none'} -> " \
          "#{resolved_phase} " \
          "layer1_lag=#{layer1_lag}"
        )
      end
    end
  end
end
