# frozen_string_literal: true

module AddressSpendStats
  class Runner
    DEFAULT_LIMIT = 10
    DEFAULT_MAX_RUNTIME_SECONDS = 30

    ADVISORY_LOCK_KEY = 48_212

    def self.call(
      limit: DEFAULT_LIMIT,
      max_runtime_seconds:
        DEFAULT_MAX_RUNTIME_SECONDS,
      lock: true
    )
      new(
        limit: limit,
        max_runtime_seconds:
          max_runtime_seconds,
        lock: lock
      ).call
    end

    def initialize(
      limit:,
      max_runtime_seconds:,
      lock:,
      next_record:
        AddressSpendStats::NextRecord,
      projector:
        AddressSpendStats::ProjectBlock,
      clock: nil
    )
      @limit =
        [
          limit.to_i,
          1
        ].max

      runtime =
        max_runtime_seconds.to_f

      @max_runtime_seconds =
        runtime.positive? ? runtime : nil

      @lock = lock == true
      @locked = false

      @next_record = next_record
      @projector = projector

      @clock =
        clock ||
        lambda do
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )
        end

      reset_metrics
    end

    def call
      started_at =
        monotonic_seconds

      result = nil

      begin
        if lock
          @locked = acquire_lock

          result =
            already_running_result unless locked
        end

        result ||=
          run(
            started_at
          )
      rescue StandardError => error
        result =
          error_result(
            error
          )
      ensure
        release_lock if lock && locked
      end

      result.merge(
        duration_metrics(
          started_at
        )
      )
    end

    private

    attr_reader(
      :limit,
      :max_runtime_seconds,
      :lock,
      :locked,
      :next_record,
      :projector,
      :clock,
      :projected_blocks,
      :idempotent_blocks,
      :input_count,
      :address_count,
      :total_sent_sats,
      :first_height,
      :last_height,
      :current_height
    )

    def reset_metrics
      @projected_blocks = 0
      @idempotent_blocks = 0
      @input_count = 0
      @address_count = 0
      @total_sent_sats = 0
      @first_height = nil
      @last_height = nil
      @current_height = nil
    end

    def run(started_at)
      stopped_reason =
        "limit_reached"

      while projected_blocks < limit
        if runtime_exceeded?(
          started_at
        )
          stopped_reason =
            "runtime_budget_exceeded"

          break
        end

        source =
          next_record.call

        unless source
          stopped_reason =
            "empty_queue"

          break
        end

        @current_height =
          source.height.to_i

        result =
          projector.call(
            height:
              current_height
          )

        record_projection(
          result
        )
      end

      success_result(
        stopped_reason
      )
    end

    def record_projection(result)
      height =
        result
          .fetch(:height)
          .to_i

      @projected_blocks += 1

      @idempotent_blocks += 1 if
        result[:idempotent] == true

      @input_count +=
        result[:input_count].to_i

      @address_count +=
        result[:address_count].to_i

      @total_sent_sats +=
        result[:total_sent_sats].to_i

      @first_height ||= height
      @last_height = height
      @current_height = nil
    end

    def runtime_exceeded?(started_at)
      return false unless
        max_runtime_seconds

      monotonic_seconds -
        started_at >=
        max_runtime_seconds
    end

    def success_result(stopped_reason)
      metrics.merge(
        ok: true,
        locked:
          lock ? locked : nil,
        stopped_reason:
          stopped_reason
      )
    end

    def error_result(error)
      metrics.merge(
        ok: false,
        locked:
          lock ? locked : nil,
        stopped_reason:
          "error",
        failed_height:
          current_height,
        error_class:
          error.class.name,
        error_message:
          error.message
      )
    end

    def already_running_result
      metrics.merge(
        ok: false,
        locked: false,
        stopped_reason:
          "already_running"
      )
    end

    def metrics
      {
        limit: limit,
        max_runtime_seconds:
          max_runtime_seconds,
        projected_blocks:
          projected_blocks,
        idempotent_blocks:
          idempotent_blocks,
        input_count:
          input_count,
        address_count:
          address_count,
        total_sent_sats:
          total_sent_sats,
        first_height:
          first_height,
        last_height:
          last_height
      }
    end

    def duration_metrics(started_at)
      duration_seconds =
        [
          monotonic_seconds -
            started_at,
          0.0
        ].max

      {
        duration_ms:
          (
            duration_seconds *
            1_000
          ).round,

        duration_seconds:
          duration_seconds.round(3),

        blocks_per_second:
          blocks_per_second(
            duration_seconds
          )
      }
    end

    def blocks_per_second(
      duration_seconds
    )
      return 0.0 unless
        duration_seconds.positive?

      (
        projected_blocks /
        duration_seconds
      ).round(2)
    end

    def acquire_lock
      value =
        ApplicationRecord
          .connection
          .select_value(
            "SELECT "             "pg_try_advisory_lock("             "#{ADVISORY_LOCK_KEY}"             ")"
          )

      value == true ||
        value == "t"
    end

    def release_lock
      ApplicationRecord
        .connection
        .select_value(
          "SELECT "           "pg_advisory_unlock("           "#{ADVISORY_LOCK_KEY}"           ")"
        )
    end

    def monotonic_seconds
      clock.call.to_f
    end
  end
end
