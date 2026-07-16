# frozen_string_literal: true

require "json"

module Layer1
  class CatchupProgressSnapshot
    MIN_OBSERVATION_SECONDS = 10.minutes.to_i
    MIN_ESTIMATION_SECONDS = 1.hour.to_i
    MIN_RECOVERED_BLOCKS_FOR_ESTIMATE = 3

    class MissingPhaseState < StandardError; end
    class InvalidPhaseState < StandardError; end

    def self.call(current_lag:, redis: nil, now: Time.current)
      new(current_lag: current_lag, redis: redis, now: now).call
    end

    def initialize(current_lag:, redis:, now:)
      @current_lag = current_lag
      @redis = redis
      @now = now
    end

    def call
      lag = normalize_nonnegative_integer(current_lag)
      return unavailable_snapshot("current_lag_unavailable") if lag.nil?

      raw_state = read_phase_state
      phase = normalize_phase_state(raw_state)
      build_snapshot(current: lag, phase: phase)
    rescue MissingPhaseState
      unavailable_snapshot("phase_state_missing")
    rescue InvalidPhaseState
      unavailable_snapshot("phase_state_invalid")
    rescue StandardError => error
      Rails.logger.warn(
        "[layer1_catchup_progress_snapshot] redis_unavailable " \
        "error_class=#{error.class.name}"
      )
      unavailable_snapshot(
        "redis_unavailable",
        error_class: error.class.name
      )
    end

    private

    attr_reader :current_lag, :redis, :now

    def read_phase_state
      raw = with_redis do |connection|
        connection.get(System::DevelopmentBackfillPhase::STATE_KEY)
      end

      raise MissingPhaseState if raw.blank?

      parsed = JSON.parse(raw)
      raise InvalidPhaseState unless parsed.is_a?(Hash)

      parsed.with_indifferent_access
    rescue JSON::ParserError
      raise InvalidPhaseState
    end

    def with_redis
      return yield(redis) if redis

      Sidekiq.redis { |connection| yield(connection) }
    end

    def normalize_phase_state(state)
      phase = state[:phase].to_s
      raise InvalidPhaseState unless
        System::DevelopmentBackfillPhase::PHASES.include?(phase)

      changed_at = parse_time(state[:changed_at])
      entered_lag = normalize_nonnegative_integer(state[:entered_layer1_lag])
      start_lag = normalize_nonnegative_integer(state[:start_lag])
      stop_lag = normalize_nonnegative_integer(state[:stop_lag])

      raise InvalidPhaseState unless
        changed_at && entered_lag && start_lag && stop_lag &&
          start_lag > stop_lag

      {
        phase: phase,
        changed_at: changed_at,
        entered_layer1_lag: entered_lag,
        start_lag: start_lag,
        stop_lag: stop_lag
      }
    end

    def build_snapshot(current:, phase:)
      downstream = phase[:phase] == "downstream_catchup"
      baseline = phase[:entered_layer1_lag]
      start_lag = phase[:start_lag]
      stop_lag = phase[:stop_lag]
      elapsed_seconds = [now.to_f - phase[:changed_at].to_f, 0.0].max
      lag_change = current - baseline
      recovered_blocks = downstream ? 0 : baseline - current
      accumulated_lag_blocks = downstream ? current - baseline : 0
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
        observed_rate.abs if observed_rate&.negative?

      estimate_hours =
        if !downstream && blocks_to_target.zero?
          0.0
        elsif estimation_ready && catchup_rate&.positive?
          (blocks_to_target.to_f / catchup_rate).round(2)
        end

      {
        source: "layer1_catchup_progress_snapshot",
        available: true,
        generated_at: now.iso8601(6),
        phase_state_key: System::DevelopmentBackfillPhase::STATE_KEY,
        phase: phase[:phase],
        phase_changed_at: phase[:changed_at].iso8601(6),
        status: status(
          phase: phase[:phase],
          current: current,
          elapsed_seconds: elapsed_seconds,
          recovered_blocks: recovered_blocks,
          stop_lag: stop_lag
        ),
        reason: nil,
        baseline_lag: baseline,
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
        started_at: phase[:changed_at].iso8601(6),
        elapsed_seconds: elapsed_seconds,
        estimation_ready: estimation_ready,
        raw_observed_change_per_hour: raw_rate,
        observed_change_per_hour: observed_rate,
        estimated_catchup_hours: estimate_hours,
        estimated_catchup_at:
          estimate_hours&.positive? ?
            (now + estimate_hours.hours).iso8601(6) :
            nil,
        error_class: nil
      }
    end

    def status(phase:, current:, elapsed_seconds:, recovered_blocks:, stop_lag:)
      return "downstream_catchup" if phase == "downstream_catchup"
      return "target_reached" if current <= stop_lag
      return "catching_up" if recovered_blocks.positive?
      return "falling_behind" if recovered_blocks.negative?
      return "measuring" if elapsed_seconds < MIN_OBSERVATION_SECONDS

      "stable"
    end

    def unavailable_snapshot(reason, error_class: nil)
      {
        source: "layer1_catchup_progress_snapshot",
        available: false,
        generated_at: now.iso8601(6),
        phase_state_key: System::DevelopmentBackfillPhase::STATE_KEY,
        phase: nil,
        status: "unavailable",
        reason: reason,
        current_lag: normalize_nonnegative_integer(current_lag),
        estimation_ready: false,
        observed_change_per_hour: nil,
        estimated_catchup_hours: nil,
        estimated_catchup_at: nil,
        error_class: error_class
      }
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_nonnegative_integer(value)
      integer = value.is_a?(String) ? Integer(value, 10) : Integer(value)
      integer unless integer.negative?
    rescue ArgumentError, TypeError
      nil
    end
  end
end
