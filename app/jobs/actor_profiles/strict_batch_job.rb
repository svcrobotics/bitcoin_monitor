# frozen_string_literal: true

require "securerandom"

module ActorProfiles
class StrictBatchJob < ApplicationJob
queue_as :actor_profile_strict

DEFAULT_WAIT_SECONDS = 15
DEFAULT_LIMIT = 5
MAX_LIMIT = 5
IMMEDIATE_RETRY_SECONDS = 1
PAUSED_RETRY_SECONDS = 15
EMPTY_BACKLOG_RETRY_SECONDS = 60
RECOVERABLE_FAILURE_RETRY_SECONDS = 15

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

CONTINUOUS_ENABLED_KEY =
  "actor_profiles:strict_batch:continuous_enabled"

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
      maximum: MAX_LIMIT
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

  started_at = Time.current
  monotonic_started_at = monotonic_ms
  token = SecureRandom.hex(16)
  lock_acquired = acquire_lock(token)
  scheduled_next = false

  unless lock_acquired
    Rails.logger.info(
      "[actor_profile_strict_batch_job] " \
      "skipped reason=locked " \
      "scheduled_next=#{scheduled_next}"
    )

    return {
      ok: true,
      status: "skipped",
      reason: "locked",
      scheduled_next: scheduled_next,
      continuous:
        continuous_payload(
          state: "batch_already_active",
          batch_size: limit_value,
          started_at: started_at,
          completed_at: Time.current,
          scheduled_next: scheduled_next,
          pause_reason: "locked"
        )
    }
  end

  # Le marqueur correspondait au job qui vient de démarrer.
  # Il ne doit être supprimé qu’après acquisition du verrou.
  clear_schedule_marker

  decision =
    System::PipelineController.decision(:actor_profile)

  unless decision[:allowed]
    retry_in =
      PAUSED_RETRY_SECONDS.seconds

    scheduled_next =
      schedule_next_once(
        limit: limit_value,
        wait: retry_in
      ) if reschedule_value

    Rails.logger.info(
      "[actor_profile_strict_batch_job] " \
      "skipped reason=pipeline_controller_denied " \
      "decision=#{decision.inspect} " \
      "retry_in=#{retry_in.to_i}s " \
      "scheduled_next=#{scheduled_next}"
    )

    return {
      ok: true,
      status: "skipped",
      reason: "pipeline_controller_denied",
      decision: decision,
      retry_in: retry_in,
      scheduled_next: scheduled_next,
      continuous:
        continuous_payload(
          state:
            state_for_denied_decision(decision),
          batch_size: limit_value,
          started_at: started_at,
          completed_at: Time.current,
          scheduled_next: scheduled_next,
          next_wait: retry_in,
          pause_reason:
            decision[:reason].to_s,
          backlog_count:
            backlog_count_from_decision(decision)
        )
    }
  end

  unless System::PipelineController.work_available?(decision)
    retry_in =
      EMPTY_BACKLOG_RETRY_SECONDS.seconds

    scheduled_next =
      schedule_next_once(
        limit: limit_value,
        wait: retry_in
      ) if reschedule_value

    begin
      ActorProfiles::OperationalSnapshot.mark_waiting(
        reason: "backlog_empty",
        result: {}
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[actor_profile_strict_batch_job] " \
        "operational_snapshot_waiting_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    return {
      ok: true,
      status: "skipped",
      reason: "backlog_empty",
      decision: decision,
      retry_in: retry_in,
      scheduled_next: scheduled_next,
      continuous:
        continuous_payload(
          state: "backlog_empty",
          batch_size: limit_value,
          started_at: started_at,
          completed_at: Time.current,
          scheduled_next: scheduled_next,
          next_wait: retry_in,
          pause_reason: "backlog_empty",
          backlog_count:
            backlog_count_from_decision(decision)
        )
    }
  end

  ActorProfiles::BatchProgress.start!(
    token: token,
    requested_limit: limit_value
  )

  result = nil

  begin
    result =
      ActorProfiles::StrictBatchBuilder.call(
        limit: limit_value,
        progress_token: token
      )

  rescue StandardError => error
    Rails.logger.warn(
      "[actor_profile_strict_batch_job] " \
      "exception error=#{error.class}: #{error.message}"
    )

    raise
  end

  begin
    ActorProfiles::OperationalSnapshot.refresh_from_batch(
      result
    )
  rescue StandardError => error
    Rails.logger.warn(
      "[actor_profile_strict_batch_job] " \
      "operational_snapshot_refresh_failed " \
      "#{error.class}: #{error.message}"
    )
  end

  next_wait =
    next_wait_for_result(result)

  scheduled_next =
    schedule_next_once(
      limit: limit_value,
      wait: next_wait
    ) if reschedule_value

  Rails.logger.info(
    "[actor_profile_strict_batch_job] " \
    "done selected=#{result[:selected]} " \
    "built=#{result[:built]} " \
    "deferred=#{result[:deferred]} " \
    "failed=#{result[:failed]} " \
    "backlog_count=#{backlog_count_from_result(result).inspect} " \
    "scheduled_next=#{scheduled_next}"
  )

  result.merge(
    automation: {
      queue: self.class.queue_name,
      limit: limit_value,
      batch_size: limit_value,
      reschedule: reschedule_value,
      scheduled_next: scheduled_next,
      wait_seconds: wait_seconds,
      next_wait_seconds: next_wait.to_i,
      continuous_mode: true
    },
    continuous:
      continuous_payload(
        state: "running",
        batch_size: limit_value,
        started_at: started_at,
        completed_at: Time.current,
        scheduled_next: scheduled_next,
        next_wait: next_wait,
        result: result,
        duration_ms:
          monotonic_ms - monotonic_started_at
      )
  )
ensure
  if defined?(token) &&
     token.present?
    ActorProfiles::BatchProgress.clear!(
      token: token
    )
  end

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

def schedule_next_once(limit:, wait: wait_seconds.seconds)
  return false unless continuous_enabled?
  return false if queued_or_scheduled_batch_present?

  marker_created =
    Sidekiq.redis do |redis|
      !!redis.set(
        SCHEDULE_KEY,
        Time.current.to_i,
        nx: true,
        ex: wait.to_i + LOCK_TTL_SECONDS
      )
    end

  return false unless marker_created

  job =
    self.class
      .set(wait: wait)
      .perform_later(
        {
          "limit" => limit,
          "reschedule" => true
        }
      )

  if job.blank?
    Sidekiq.redis do |redis|
      redis.del(SCHEDULE_KEY)
    end

    return false
  end

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

def continuous_enabled?
  Sidekiq.redis do |redis|
    redis.call(
      "GET",
      CONTINUOUS_ENABLED_KEY
    ).to_s == "1"
  end
rescue StandardError => error
  Rails.logger.warn(
    "[actor_profile_strict_batch_job] " \
    "continuous_enabled_check_failed " \
    "#{error.class}: #{error.message}"
  )

  false
end

def safe_schedule_next_once(limit:, wait:, enabled:)
  return false unless enabled

  schedule_next_once(
    limit: limit,
    wait: wait
  )
rescue StandardError => error
  Rails.logger.warn(
    "[actor_profile_strict_batch_job] " \
    "safe_schedule_failed " \
    "#{error.class}: #{error.message}"
  )

  false
end

def queued_or_scheduled_batch_present?
  require "sidekiq/api"

  queue_present =
    Sidekiq::Queue
      .new(self.class.queue_name)
      .any? do |job|
        job.item.to_s.include?(
          self.class.name
        )
      end

  return true if queue_present

  Sidekiq::ScheduledSet
    .new
    .any? do |job|
      job.queue == self.class.queue_name.to_s &&
        job.item.to_s.include?(
          self.class.name
        )
    end
rescue StandardError => error
  Rails.logger.warn(
    "[actor_profile_strict_batch_job] " \
    "queued_or_scheduled_check_failed " \
    "#{error.class}: #{error.message}"
  )

  false
end

def next_wait_for_result(result)
  backlog_count =
    backlog_count_from_result(result)

  return EMPTY_BACKLOG_RETRY_SECONDS.seconds if
    backlog_count == 0

  if result[:status].to_s == "deferred"
    return PAUSED_RETRY_SECONDS.seconds
  end

  if result[:ok] == false ||
     result[:failed].to_i.positive?
    return RECOVERABLE_FAILURE_RETRY_SECONDS.seconds
  end

  IMMEDIATE_RETRY_SECONDS.seconds
end

def backlog_count_from_result(result)
  return nil unless result.is_a?(Hash)

  missing =
    result[:missing_profiles_count]

  stale =
    result[:stale_profiles_count]

  return nil if missing.nil? || stale.nil?

  missing.to_i + stale.to_i
end

def backlog_count_from_decision(decision)
  decision
    .dig(:snapshot, :actor_profile, :pending_work)
    &.to_i
end

def state_for_denied_decision(decision)
  failed =
    Array(
      decision[:failed_constraints]
    ).map(&:to_sym)

  return "waiting_for_certified_cluster" if
    failed.include?(:cluster_checkpoint_available) ||
    failed.include?(:actor_profile_checkpoint_available)

  return "paused_for_layer1" if
    failed.any? do |constraint|
      constraint.to_s.start_with?("layer1_") ||
        constraint.to_s.include?("_layer1_")
    end

  return "paused_for_cluster" if
    failed.any? do |constraint|
      constraint.to_s.start_with?("cluster_") ||
        constraint.to_s.include?("_cluster_")
    end

  "waiting_for_certified_cluster"
end

def continuous_payload(
  state:,
  batch_size:,
  started_at:,
  completed_at:,
  scheduled_next:,
  next_wait: nil,
  pause_reason: nil,
  backlog_count: nil,
  result: nil,
  duration_ms: nil
)
  result ||= {}
  duration_ms ||= elapsed_wall_ms(
    started_at,
    completed_at
  )
  backlog_count =
    backlog_count_from_result(result) if
      backlog_count.nil?

  next_attempt_at =
    if scheduled_next && next_wait
      completed_at + next_wait
    end

  built_count =
    result[:built].to_i

  {
    continuous_mode: true,
    state: state,
    backlog_count: backlog_count,
    batch_size: batch_size,
    active_batch: false,
    last_batch_started_at: started_at,
    last_batch_completed_at: completed_at,
    last_batch_duration_ms: duration_ms,
    last_batch_built_count: built_count,
    last_batch_certified_count: built_count,
    last_batch_deferred_count: result[:deferred].to_i,
    last_batch_failed_count: result[:failed].to_i,
    next_attempt_at: next_attempt_at,
    pause_reason: pause_reason,
    profiles_per_hour:
      profiles_per_hour(
        built_count: built_count,
        duration_ms: duration_ms
      )
  }
end

def profiles_per_hour(built_count:, duration_ms:)
  return 0.0 unless duration_ms.to_i.positive?

  (
    built_count.to_f *
      3_600_000.0 /
      duration_ms.to_i
  ).round(2)
end

def elapsed_wall_ms(started_at, completed_at)
  [
    (
      (completed_at - started_at) *
        1000
    ).round,
    0
  ].max
end

def monotonic_ms
  (
    Process.clock_gettime(
      Process::CLOCK_MONOTONIC
    ) * 1000
  ).round
end

def wait_seconds
  integer_option(
    ENV.fetch(
      "ACTOR_PROFILE_STRICT_WAIT_SECONDS",
      DEFAULT_WAIT_SECONDS.to_s
    ),
    default: DEFAULT_WAIT_SECONDS,
    minimum: 1,
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
