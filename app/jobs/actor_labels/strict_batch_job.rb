# frozen_string_literal: true

require "json"
require "securerandom"

module ActorLabels
class StrictBatchJob < ApplicationJob
queue_as :actor_labels_strict

DEFAULT_LIMIT = 500
DEFAULT_WAIT_SECONDS = 60

# Un lot de 1 000 profils peut durer plusieurs minutes.
# Le verrou ne doit pas expirer pendant son exécution.
LOCK_TTL_SECONDS =
  Integer(
    ENV.fetch(
      "ACTOR_LABEL_STRICT_LOCK_TTL_SECONDS",
      "3600"
    )
  )

LOCK_KEY = "actor_labels:strict_batch:lock"
CURSOR_KEY = "actor_labels:strict_batch:cursor"
SCHEDULE_KEY = "actor_labels:strict_batch:scheduled"
LAST_RUN_KEY = "actor_labels:strict_batch:last_run"

def perform(options = {})
  options = options.to_h.symbolize_keys

  limit =
    integer_option(
      options[:limit],
      DEFAULT_LIMIT,
      minimum: 1,
      maximum: ActorLabels::StrictBatch::MAX_LIMIT
    )

  wait_seconds =
    integer_option(
      options[:wait_seconds],
      DEFAULT_WAIT_SECONDS,
      minimum: 10,
      maximum: 3_600
    )

  schedule_next =
    boolean_option(
      options[:schedule_next],
      default: true
    )

  persist_cursor =
    boolean_option(
      options[:persist_cursor],
      default: true
    )

  explicit_after_id = options[:after_id]
  token = SecureRandom.hex(16)

  lock_acquired = acquire_lock(token)

  unless lock_acquired
    Rails.logger.info(
      "[actor_labels_strict] skipped reason=locked"
    )

    return {
      ok: true,
      skipped: true,
      reason: "locked",
      write_enabled: write_enabled?
    }
  end

  # Le marqueur représentait le job qui vient de commencer.
  # Il ne doit être supprimé qu’après acquisition du verrou.
  clear_schedule_marker

  after_id =
    if explicit_after_id.nil?
      current_cursor
    else
      [explicit_after_id.to_i, 0].max
    end

  result =
    ActorLabels::StrictBatch.call(
      limit: limit,
      after_id: after_id,
      dry_run: !write_enabled?
    )

  next_cursor =
    result
      .dig(:cursor, :next_after_id)
      .to_i

  save_last_run(
    result: result,
    after_id: after_id,
    next_cursor: next_cursor,
    persist_cursor: persist_cursor,
    schedule_next: schedule_next,
    wait_seconds: wait_seconds
  )

  unless result[:ok]
    failed = result.dig(:batch, :failed).to_i

    raise(
      "ActorLabels strict batch failed " \
      "failed=#{failed} " \
      "after_id=#{after_id}"
    )
  end

  save_cursor(next_cursor) if persist_cursor

  scheduled_next =
    if schedule_next
      schedule_next_once(
        limit: limit,
        wait_seconds: wait_seconds
      )
    else
      false
    end

  Rails.logger.info(
    "[actor_labels_strict] " \
    "scanned=#{result.dig(:batch, :scanned)} " \
    "eligible=#{result.dig(:batch, :eligible)} " \
    "expected=#{result.dig(:batch, :expected_labels)} " \
    "written=#{result.dig(:batch, :written_labels)} " \
    "failed=#{result.dig(:batch, :failed)} " \
    "after_id=#{after_id} " \
    "next_cursor=#{next_cursor} " \
    "scheduled_next=#{scheduled_next} " \
    "write_enabled=#{write_enabled?}"
  )

  result.merge(
    automation: {
      queue: self.class.queue_name,
      write_enabled: write_enabled?,
      cursor_persisted: persist_cursor,
      persisted_cursor:
        persist_cursor ? next_cursor : current_cursor,
      schedule_next: schedule_next,
      scheduled_next: scheduled_next,
      wait_seconds: wait_seconds
    }
  )
ensure
  if defined?(lock_acquired) &&
     lock_acquired &&
     defined?(token) &&
     token.present?
    release_lock(token)
  end
end

private

def write_enabled?
  ActiveModel::Type::Boolean.new.cast(
    ENV.fetch(
      "ACTOR_LABEL_WRITE_ENABLED",
      "false"
    )
  )
end

def acquire_lock(token)
  Sidekiq.redis do |redis|
    !!redis.set(
      LOCK_KEY,
      token,
      nx: true,
      ex: LOCK_TTL_SECONDS
    )
  end
end

def release_lock(token)
  Sidekiq.redis do |redis|
    if redis.get(LOCK_KEY) == token
      redis.del(LOCK_KEY)
    end
  end
rescue StandardError => error
  Rails.logger.warn(
    "[actor_labels_strict] lock_release_failed " \
    "#{error.class}: #{error.message}"
  )
end

def current_cursor
  Sidekiq.redis do |redis|
    redis.get(CURSOR_KEY).to_i
  end
rescue StandardError
  0
end

def save_cursor(cursor)
  Sidekiq.redis do |redis|
    redis.set(
      CURSOR_KEY,
      [cursor.to_i, 0].max
    )
  end
end

def clear_schedule_marker
  Sidekiq.redis do |redis|
    redis.del(SCHEDULE_KEY)
  end
rescue StandardError => error
  Rails.logger.warn(
    "[actor_labels_strict] " \
    "schedule_marker_clear_failed " \
    "#{error.class}: #{error.message}"
  )
end

def save_last_run(
  result:,
  after_id:,
  next_cursor:,
  persist_cursor:,
  schedule_next:,
  wait_seconds:
)
  payload = {
    ran_at: Time.current.iso8601(6),
    ok: result[:ok],
    dry_run: result[:dry_run],
    write_enabled: write_enabled?,

    after_id: after_id,
    next_cursor: next_cursor,
    persist_cursor: persist_cursor,

    schedule_next: schedule_next,
    wait_seconds: wait_seconds,

    cluster_tip:
      result.dig(:heights, :cluster_tip),

    batch: result[:batch],
    rejected_by_reason:
      result[:rejected_by_reason],

    runtime_ms: result[:runtime_ms]
  }

  Sidekiq.redis do |redis|
    redis.set(
      LAST_RUN_KEY,
      JSON.generate(payload),
      ex: 86_400
    )
  end
rescue StandardError => error
  Rails.logger.warn(
    "[actor_labels_strict] last_run_save_failed " \
    "#{error.class}: #{error.message}"
  )
end

def schedule_next_once(limit:, wait_seconds:)
  marker_created =
    Sidekiq.redis do |redis|
      !!redis.set(
        SCHEDULE_KEY,
        Time.current.to_i,
        nx: true,
        ex: wait_seconds + LOCK_TTL_SECONDS
      )
    end

  return false unless marker_created

  self.class
    .set(wait: wait_seconds.seconds)
    .perform_later(
      {
        "limit" => limit,
        "wait_seconds" => wait_seconds,
        "schedule_next" => true,
        "persist_cursor" => true
      }
    )

  true
rescue StandardError => error
  Sidekiq.redis do |redis|
    redis.del(SCHEDULE_KEY)
  end

  Rails.logger.error(
    "[actor_labels_strict] scheduling_failed " \
    "#{error.class}: #{error.message}"
  )

  raise
end

def boolean_option(value, default:)
  return default if value.nil?

  ActiveModel::Type::Boolean
    .new
    .cast(value)
end

def integer_option(
  value,
  default,
  minimum:,
  maximum:
)
  integer = Integer(value || default)

  [
    [integer, minimum].max,
    maximum
  ].min
rescue ArgumentError, TypeError
  default
end


end
end
