# frozen_string_literal: true

require "json"

module Layer1
  class CatchupProgressSnapshot
    PHASE_KEY =
      "tansa:pipeline:development_backfill:phase"

    MIN_OBSERVATION_SECONDS = 10.minutes.to_i
    MIN_ESTIMATION_SECONDS = 1.hour.to_i
    MIN_RECOVERED_BLOCKS_FOR_ESTIMATE = 3
    DEFAULT_START_LAG = 10
    DEFAULT_STOP_LAG = 2

    def self.call(current_lag:, phase_state: nil, redis: nil, now: Time.current)
      new(
        current_lag: current_lag,
        phase_state: phase_state,
        redis: redis,
        now: now
      ).call
    end

    def initialize(current_lag:, phase_state:, redis:, now:)
      @current_lag = current_lag
      @phase_state = phase_state
      @redis = redis
      @now = now
    end

    def call
      return unavailable_snapshot if current_lag.blank?

      with_redis do |connection|
        phase = normalized_phase_state(
          phase_state || read_json(connection, PHASE_KEY)
        )
        build_snapshot(phase)
      end
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_catchup_progress_snapshot] " \
        "#{error.class}: #{error.message}"
      )
      unavailable_snapshot(error: "#{error.class}: #{error.message}")
    end

    private

    attr_reader :current_lag, :phase_state, :redis, :now

    def with_redis
      return yield(redis) if redis
      Sidekiq.redis { |connection| yield(connection) }
    end

    def normalized_phase_state(value)
      state = value.respond_to?(:to_h) ? value.to_h : {}
      state = state.with_indifferent_access

      {
        phase: state[:phase].presence || "unknown",
        changed_at: state[:changed_at],
        entered_layer1_lag: state[:entered_layer1_lag],
        observed_layer1_lag: state[:observed_layer1_lag],
        start_lag: integer_value(state[:start_lag], DEFAULT_START_LAG),
        stop_lag: integer_value(state[:stop_lag], DEFAULT_STOP_LAG)
      }
    end

    def build_snapshot(phase)
      downstream = phase[:phase].to_s == "downstream_catchup"
      start_lag = phase[:start_lag].to_i
      stop_lag = phase[:stop_lag].to_i
      baseline_lag =
        integer_value(
          phase[:entered_layer1_lag],
          integer_value(phase[:observed_layer1_lag], current_lag.to_i)
        )
      started_at = parse_time(phase[:changed_at]) || now
      elapsed_seconds = [now.to_f - started_at.to_f, 0].max
      current = current_lag.to_i
      lag_change = current - baseline_lag
      recovered_blocks = downstream ? 0 : baseline_lag - current
      accumulated_lag_blocks = downstream ? current - baseline_lag : 0
      target_lag = downstream ? start_lag : stop_lag
      blocks_to_target =
        if downstream
          [start_lag - current, 0].max
        else
          [current - stop_lag, 0].max
        end

      raw_rate =
        if elapsed_seconds.positive?
          (lag_change.to_f / elapsed_seconds * 3600.0).round(2)
        end

      estimation_ready =
        !downstream &&
        elapsed_seconds >= MIN_ESTIMATION_SECONDS &&
        recovered_blocks >= MIN_RECOVERED_BLOCKS_FOR_ESTIMATE

      observed_rate = estimation_ready ? raw_rate : nil
      catchup_rate =
        if observed_rate.present? && observed_rate.negative?
          observed_rate.abs
        end

      estimate_hours =
        if !downstream && blocks_to_target.zero?
          0.0
        elsif estimation_ready && catchup_rate.present? && catchup_rate.positive?
          (blocks_to_target.to_f / catchup_rate).round(2)
        end

      {
        source: "layer1_catchup_progress_snapshot",
        generated_at: now,
        phase: phase[:phase],
        phase_changed_at: phase[:changed_at],
        status: status(
          phase: phase[:phase],
          elapsed_seconds: elapsed_seconds,
          recovered_blocks: recovered_blocks,
          stop_lag: stop_lag
        ),
        baseline_lag: baseline_lag,
        current_lag: current,
        start_lag: start_lag,
        stop_lag: stop_lag,
        target_lag: target_lag,
        target_kind: downstream ? "resume_layer1" : "stop_layer1",
        blocks_to_target: blocks_to_target,
        progress_blocks: downstream ? accumulated_lag_blocks : recovered_blocks,
        recovered_blocks: recovered_blocks,
        accumulated_lag_blocks: accumulated_lag_blocks,
        lag_change: lag_change,
        started_at: started_at,
        elapsed_seconds: elapsed_seconds,
        estimation_ready: estimation_ready,
        raw_observed_change_per_hour: raw_rate,
        observed_change_per_hour: observed_rate,
        estimated_catchup_hours: estimate_hours,
        estimated_catchup_at:
          estimate_hours.present? && estimate_hours.positive? ?
            now + estimate_hours.hours :
            nil
      }
    end

    def status(phase:, elapsed_seconds:, recovered_blocks:, stop_lag:)
      return "downstream_catchup" if phase == "downstream_catchup"
      return "target_reached" if current_lag.to_i <= stop_lag
      return "catching_up" if recovered_blocks.positive?
      return "falling_behind" if recovered_blocks.negative?
      return "measuring" if elapsed_seconds < MIN_OBSERVATION_SECONDS
      "stable"
    end

    def unavailable_snapshot(error: nil)
      {
        source: "layer1_catchup_progress_snapshot",
        generated_at: now,
        status: "unavailable",
        current_lag: current_lag,
        estimation_ready: false,
        error: error
      }
    end

    def read_json(connection, key)
      raw = connection.get(key)
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    def parse_time(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def integer_value(value, fallback)
      Integer(value)
    rescue ArgumentError, TypeError
      fallback.to_i
    end
  end
end
