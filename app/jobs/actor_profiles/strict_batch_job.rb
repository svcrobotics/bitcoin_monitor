# frozen_string_literal: true

require "securerandom"

module ActorProfiles
class StrictBatchJob < ApplicationJob
queue_as :actor_profile_strict

DEFAULT_WAIT_SECONDS = 30
DEFAULT_LIMIT = 50

LOCK_TTL_SECONDS =
  Integer(
    ENV.fetch(
      "ACTOR_PROFILE_STRICT_LOCK_TTL_SECONDS",
      "3600"
    )
  )

LOCK_KEY =
  "actor_profiles:strict_batch:lock"

SCHEDULE_KEY =
  "actor_profiles:strict_batch:scheduled"

def perform(
  options = nil,
  limit: nil,
  reschedule: true
)
  normalized = normalize_options(options)

  limit_value =
    integer_option(
      normalized[:limit] || limit,
      default: Integer(
        ENV.fetch(
          "ACTOR_PROFILE_STRICT_BATCH_LIMIT",
          DEFAULT_LIMIT.to_s
        )
      ),
      minimum: 1,
      maximum: 1_000
    )

  reschedule_value =
    if normalized.key?(:reschedule)
      boolean_option(
        normalized[:reschedule],
        default: true
      )
    else
      boolean_option(
        reschedule,
        default: true
      )
    end

  token = SecureRandom.hex(16)
  lock_acquired = acquire_lock(token)
  scheduled_next = false

  unless lock_acquired
    scheduled_next =
      schedule_next_once(limit: limit_value) if reschedule_value

    Rails.logger.info(
      "[actor_profile_strict_batch_job] " \
      "skipped reason=locked " \
      "scheduled_next=#{scheduled_next}"
    )

    return {
      ok: true,
      status: "skipped",
      reason: "locked",
      scheduled_next: scheduled_next
    }
  end

  # Le marqueur correspondait au job qui vient de démarrer.
  # Il ne doit être supprimé qu’après acquisition du verrou.
  clear_schedule_marker

  if strict_pipeline_busy?
    scheduled_next =
      schedule_next_once(limit: limit_value) if reschedule_value

    Rails.logger.info(
      "[actor_profile_strict_batch_job] " \
      "skipped reason=strict_pipeline_busy " \
      "scheduled_next=#{scheduled_next}"
    )

    return {
      ok: true,
      status: "skipped",
      reason: "strict_pipeline_busy",
      scheduled_next: scheduled_next
    }
  end

  result =
    ActorProfiles::StrictBatchBuilder.call(
      limit: limit_value
    )

  unless result[:ok]
    raise(
      "ActorProfile strict batch failed " \
      "selected=#{result[:selected]} " \
      "built=#{result[:built]} " \
      "failed=#{result[:failed]}"
    )
  end

  scheduled_next =
    schedule_next_once(limit: limit_value) if reschedule_value

  Rails.logger.info(
    "[actor_profile_strict_batch_job] " \
    "done selected=#{result[:selected]} " \
    "built=#{result[:built]} " \
    "failed=#{result[:failed]} " \
    "scheduled_next=#{scheduled_next}"
  )

  result.merge(
    automation: {
      queue: self.class.queue_name,
      limit: limit_value,
      reschedule: reschedule_value,
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

def normalize_options(options)
  return {} unless options.is_a?(Hash)

  if options.respond_to?(:with_indifferent_access)
    options.with_indifferent_access
  else
    options
  end
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
    redis.del(LOCK_KEY) if redis.get(LOCK_KEY) == token
  end
rescue StandardError => error
  Rails.logger.warn(
    "[actor_profile_strict_batch_job] " \
    "lock_release_failed " \
    "#{error.class}: #{error.message}"
  )
end

def clear_schedule_marker
  Sidekiq.redis do |redis|
    redis.del(SCHEDULE_KEY)
  end
rescue StandardError => error
  Rails.logger.warn(
    "[actor_profile_strict_batch_job] " \
    "schedule_marker_clear_failed " \
    "#{error.class}: #{error.message}"
  )
end

def schedule_next_once(limit:)
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
        "reschedule" => true
      }
    )

  true
rescue StandardError => error
  Sidekiq.redis do |redis|
    redis.del(SCHEDULE_KEY)
  end

  Rails.logger.error(
    "[actor_profile_strict_batch_job] " \
    "scheduling_failed " \
    "#{error.class}: #{error.message}"
  )

  raise
end

def strict_pipeline_busy?
  layer1 = Layer1::HealthSnapshot.call

  layer1_tip =
    layer1.dig(:sync, :processed_height) ||
    layer1[:processed_height]

  layer1_lag =
    layer1.dig(:sync, :lag) ||
    layer1[:lag]

  buffers = layer1[:buffers] || {}

  outputs_buffer =
    buffers[:outputs].to_i

  spent_buffer =
    buffers[:spent].to_i

  cluster_tip =
    if defined?(ClusterProcessedBlock)
      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
    end

  max_safe_layer1_lag =
    Integer(
      ENV.fetch(
        "ACTOR_PROFILE_WAIT_LAYER1_LAG_GT",
        "3"
      )
    )

  return true if outputs_buffer.positive?
  return true if spent_buffer.positive?

  if layer1_tip.present? &&
     cluster_tip.to_i < layer1_tip.to_i
    return true
  end

  return true if layer1_lag.to_i > max_safe_layer1_lag

  false
rescue StandardError => error
  Rails.logger.warn(
    "[actor_profile_strict_batch_job] " \
    "strict_pipeline_busy_check_failed " \
    "#{error.class}: #{error.message}"
  )

  false
end

def wait_seconds
  integer_option(
    ENV.fetch(
      "ACTOR_PROFILE_STRICT_WAIT_SECONDS",
      DEFAULT_WAIT_SECONDS.to_s
    ),
    default: DEFAULT_WAIT_SECONDS,
    minimum: 10,
    maximum: 3_600
  )
end

def boolean_option(value, default:)
  return default if value.nil?

  ActiveModel::Type::Boolean
    .new
    .cast(value)
end

def integer_option(
  value,
  default:,
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
