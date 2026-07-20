# frozen_string_literal: true

require "json"
require "securerandom"

module ActorLabels
  class FullAudit
    DEFAULT_LIMIT = 500

    CURSOR_KEY =
      "actor_labels:full_audit:cursor"

    STATE_KEY =
      "actor_labels:full_audit:state"

    LAST_RUN_KEY =
      "actor_labels:full_audit:last_run"

    REPORT_TTL_SECONDS =
      30.days.to_i

    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit =
        normalize_limit(limit)
    end

    def call
      token =
        SecureRandom.hex(16)

      acquired =
        acquire_lock(token)

      return locked_result unless acquired

      after_id =
        current_cursor

      state =
        current_state

      if after_id.positive? && state.nil?
        return missing_state_result(
          after_id
        )
      end

      state ||=
        initial_state(
          after_id
        )

      result =
        ActorLabels::StrictBatch.call(
          limit: limit,
          after_id: after_id,
          dry_run: true
        )

      return failed_result(
        result,
        after_id
      ) unless result[:ok]

      next_cursor =
        result
          .dig(:cursor, :next_after_id)
          .to_i

      state =
        aggregate(
          state,
          result,
          next_cursor
        )

      if result.dig(:cursor, :has_more)
        save_progress(
          cursor: next_cursor,
          state: state
        )

        result.merge(
          audit:
            state
              .merge(
                "status" => "running"
              )
              .deep_symbolize_keys
        )
      else
        complete_audit(
          result,
          state
        )
      end
    ensure
      if defined?(acquired) &&
         acquired &&
         defined?(token) &&
         token.present?
        release_lock(token)
      end
    end

    private

    attr_reader :limit

    def normalize_limit(value)
      integer =
        Integer(value)

      [
        [integer, 1].max,
        ActorLabels::StrictBatch::MAX_LIMIT
      ].min
    rescue ArgumentError, TypeError
      DEFAULT_LIMIT
    end

    def acquire_lock(token)
      Sidekiq.redis do |redis|
        !!redis.set(
          ActorLabels::StrictBatchJob::LOCK_KEY,
          token,
          nx: true,
          ex:
            ActorLabels::StrictBatchJob::
              LOCK_TTL_SECONDS
        )
      end
    end

    def release_lock(token)
      Sidekiq.redis do |redis|
        if redis.get(
          ActorLabels::StrictBatchJob::LOCK_KEY
        ) == token
          redis.del(
            ActorLabels::StrictBatchJob::LOCK_KEY
          )
        end
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_labels_full_audit] " \
        "lock_release_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def current_cursor
      Sidekiq.redis do |redis|
        redis.get(CURSOR_KEY).to_i
      end
    end

    def current_state
      raw =
        Sidekiq.redis do |redis|
          redis.get(STATE_KEY)
        end

      return if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def initial_state(after_id)
      {
        "started_at" =>
          Time.current.iso8601(6),

        "initial_cursor" =>
          after_id,

        "last_cursor" =>
          after_id,

        "batches" => 0,
        "scanned" => 0,
        "eligible" => 0,
        "ineligible" => 0,
        "failed" => 0,
        "expected_labels" => 0,
        "expected_upserts" => 0,
        "expected_deletions" => 0,
        "runtime_ms" => 0,
        "expected_by_label" => {}
      }
    end

    def aggregate(
      state,
      result,
      next_cursor
    )
      batch =
        result.fetch(:batch)

      state["batches"] += 1
      state["last_cursor"] = next_cursor

      %w[
        scanned
        eligible
        ineligible
        failed
        expected_labels
        expected_upserts
        expected_deletions
      ].each do |key|
        state[key] +=
          batch[key.to_sym].to_i
      end

      state["runtime_ms"] +=
        result[:runtime_ms].to_i

      expected_by_label =
        batch[:expected_by_label].to_h

      expected_by_label.each do |label, count|
        state["expected_by_label"][label.to_s] =
          state["expected_by_label"]
            .fetch(label.to_s, 0) +
          count.to_i
      end

      state
    end

    def save_progress(cursor:, state:)
      Sidekiq.redis do |redis|
        redis.set(
          CURSOR_KEY,
          [cursor.to_i, 0].max
        )

        redis.set(
          STATE_KEY,
          JSON.generate(state)
        )
      end
    end

    def complete_audit(result, state)
      global_deletions =
        result
          .dig(
            :reconciliation,
            :expected_deletions
          )
          .to_i

      state["status"] = "completed"
      state["completed_at"] =
        Time.current.iso8601(6)

      state["global_expected_deletions"] =
        global_deletions

      state["drift_total"] =
        state["expected_upserts"] +
        state["expected_deletions"] +
        global_deletions

      state["strict_labels_stored"] =
        result
          .dig(
            :database,
            :strict_actor_labels
          )
          .to_i

      Sidekiq.redis do |redis|
        redis.set(
          LAST_RUN_KEY,
          JSON.generate(state),
          ex: REPORT_TTL_SECONDS
        )

        redis.del(
          CURSOR_KEY,
          STATE_KEY
        )
      end

      result.merge(
        audit:
          state.deep_symbolize_keys
      )
    end

    def locked_result
      {
        ok: true,
        skipped: true,
        reason: "locked",
        audit: {
          status: "waiting_for_incremental"
        }
      }
    end

    def missing_state_result(after_id)
      {
        ok: false,
        skipped: true,
        reason: "audit_state_missing",
        audit: {
          status: "blocked",
          cursor: after_id
        }
      }
    end

    def failed_result(result, after_id)
      result.merge(
        audit: {
          status: "failed",
          cursor: after_id
        }
      )
    end
  end
end
