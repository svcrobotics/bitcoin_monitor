# frozen_string_literal: true

require "sidekiq/api"
require "json"
require "securerandom"

module StrictPipeline
  class SchedulerWatchdog
    LOCK_KEY = "strict_pipeline:scheduler_watchdog:lock"
    LOCK_TTL_SECONDS = 30

    JobSpec = Struct.new(
      :name,
      :queue,
      :klass,
      :kind,
      :wait_seconds,
      :args,
      keyword_init: true
    )

    def self.call
      new.call
    end

    def initialize(redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
      @redis = redis
    end

    def call
      return { ok: true, skipped: true, reason: "locked" } unless acquire_lock

      {
        ok: true,
        checked_at: Time.current,
        jobs: job_specs.map { |spec| check_job(spec) }
      }
    ensure
      release_lock
    end

    private

    def job_specs
      [
        JobSpec.new(
          name: "layer1",
          queue: "layer1_strict",
          klass: "Layer1::StrictTipSyncJob",
          kind: :sidekiq,
          wait_seconds: 5,
          args: [true]
        ),
        JobSpec.new(
          name: "cluster",
          queue: "cluster_strict",
          klass: "Clusters::StrictTipSyncJob",
          kind: :active_job,
          wait_seconds: 10,
          args: [{ limit: Integer(ENV.fetch("CLUSTER_STRICT_SYNC_LIMIT", "2")), reschedule: true }]
        ),
        JobSpec.new(
          name: "actor_profile",
          queue: "actor_profile_strict",
          klass: "ActorProfiles::StrictBatchJob",
          kind: :active_job,
          wait_seconds: 15,
          args: [{ limit: Integer(ENV.fetch("ACTOR_PROFILE_STRICT_BATCH_LIMIT", "50")), reschedule: true }]
        )
      ]
    end

    def check_job(spec)
      process_present = process_present_for_queue?(spec.queue)

      scheduled_jobs = matching_scheduled_jobs(spec)
      queued_jobs = matching_queued_jobs(spec)
      active = active_count(spec)

      cleanup = cleanup_duplicates(
        scheduled_jobs: scheduled_jobs,
        queued_jobs: queued_jobs,
        active: active
      )

      scheduled = [scheduled_jobs.size - cleanup[:scheduled_deleted], 0].max
      queued = [queued_jobs.size - cleanup[:queued_deleted], 0].max
      present = (scheduled + queued + active).positive?

      result = {
        name: spec.name,
        queue: spec.queue,
        klass: spec.klass,
        process_present: process_present,
        scheduled: scheduled,
        queued: queued,
        active: active,
        present: present,
        repaired: false,
        duplicates_removed: cleanup
      }

      return result.merge(skipped: true, reason: "worker_not_running") unless process_present
      return result if present

      repair(spec)
      result.merge(repaired: true)
    rescue StandardError => e
      {
        name: spec.name,
        queue: spec.queue,
        klass: spec.klass,
        present: false,
        repaired: false,
        error_class: e.class.name,
        message: e.message
      }
    end

    def cleanup_duplicates(scheduled_jobs:, queued_jobs:, active:)
      scheduled_deleted = 0
      queued_deleted = 0

      if active.positive?
        scheduled_jobs.each { |job| job.delete; scheduled_deleted += 1 }
        queued_jobs.each { |job| job.delete; queued_deleted += 1 }

        return { scheduled_deleted: scheduled_deleted, queued_deleted: queued_deleted, kept: "active" }
      end

      if queued_jobs.any?
        queued_jobs.drop(1).each { |job| job.delete; queued_deleted += 1 }
        scheduled_jobs.each { |job| job.delete; scheduled_deleted += 1 }

        return { scheduled_deleted: scheduled_deleted, queued_deleted: queued_deleted, kept: "queued" }
      end

      if scheduled_jobs.any?
        sorted = scheduled_jobs.sort_by { |job| job.at || Time.current.to_f }

        sorted.drop(1).each do |job|
          job.delete
          scheduled_deleted += 1
        end

        return { scheduled_deleted: scheduled_deleted, queued_deleted: queued_deleted, kept: "scheduled" }
      end

      { scheduled_deleted: 0, queued_deleted: 0, kept: nil }
    end

    def repair(spec)
      klass = spec.klass.constantize

      case spec.kind
      when :sidekiq
        klass.perform_in(spec.wait_seconds, *Array(spec.args))
      when :active_job
        klass.set(wait: spec.wait_seconds.seconds).perform_later(*Array(spec.args))
      else
        raise ArgumentError, "unknown job kind #{spec.kind.inspect}"
      end
    end

    def process_present_for_queue?(queue_name)
      Sidekiq::ProcessSet.new.any? do |process|
        Array(process["queues"]).include?(queue_name)
      end
    end

    def matching_scheduled_jobs(spec)
      Sidekiq::ScheduledSet.new.select do |job|
        job_queue(job) == spec.queue && payload_matches?(job.item, spec)
      end
    end

    def matching_queued_jobs(spec)
      Sidekiq::Queue.new(spec.queue).select do |job|
        payload_matches?(job.item, spec)
      end
    end

    def active_count(spec)
      Sidekiq::Workers.new.count do |_process_id, _thread_id, work|
        worker_queue(work) == spec.queue && payload_matches?(worker_payload(work), spec)
      end
    end

    def job_queue(job)
      return job.queue if job.respond_to?(:queue)

      item = job.item rescue {}
      item["queue"]
    end

    def payload_matches?(payload, spec)
      payload = parse_payload(payload)

      return true if payload["class"].to_s == spec.klass
      return true if payload["wrapped"].to_s == spec.klass

      active_job_payload = Array(payload["args"]).first
      active_job_payload.is_a?(Hash) && active_job_payload["job_class"].to_s == spec.klass
    end

    def worker_queue(work)
      return work.queue if work.respond_to?(:queue)

      h = worker_hash(work)
      h["queue"] || h[:queue]
    end

    def worker_payload(work)
      return work.payload if work.respond_to?(:payload)

      h = worker_hash(work)
      h["payload"] || h[:payload] || h
    end

    def worker_hash(work)
      if work.respond_to?(:to_h)
        work.to_h
      elsif work.instance_variable_defined?(:@hsh)
        work.instance_variable_get(:@hsh)
      else
        {}
      end
    end

    def parse_payload(payload)
      payload = JSON.parse(payload) if payload.is_a?(String)
      payload || {}
    rescue JSON::ParserError
      {}
    end

    def acquire_lock
      @lock_value = SecureRandom.uuid
      @redis.set(LOCK_KEY, @lock_value, nx: true, ex: LOCK_TTL_SECONDS)
    end

    def release_lock
      return if @lock_value.blank?

      script = <<~LUA
        if redis.call("get", KEYS[1]) == ARGV[1] then
          return redis.call("del", KEYS[1])
        else
          return 0
        end
      LUA

      @redis.eval(script, keys: [LOCK_KEY], argv: [@lock_value])
    rescue StandardError
      nil
    end
  end
end
