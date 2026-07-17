# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class StrictBatchJobTest < ActiveJob::TestCase
    test "job does not reschedule itself" do
      source =
        Rails.root.join(
          "app/jobs/actor_labels/strict_batch_job.rb"
        ).read

      refute_match(/perform_in/, source)
      refute_match(/set\(wait:/, source)
      refute_match(/schedule_next_once/, source)
    end

    test "write mode is disabled by default" do
      with_env("ACTOR_LABEL_WRITE_ENABLED" => nil) do
        result =
          run_with_stubbed_batch

        assert_equal false,
                     result.dig(:automation, :write_enabled)

        assert_equal false,
                     @worker_status_payload["write_enabled"]
      end
    end

    test "write mode is enabled only by explicit environment" do
      with_env("ACTOR_LABEL_WRITE_ENABLED" => "true") do
        result =
          run_with_stubbed_batch

        assert_equal true,
                     result.dig(:automation, :write_enabled)

        assert_equal true,
                     @worker_status_payload["write_enabled"]

        assert_equal(
          "actor_labels_strict",
          @worker_status_payload["queue_name"]
        )
      end
    end

    private

    def run_with_stubbed_batch
      with_stubbed(
        ActorLabels::StrictBatch,
        :call,
        batch_result
      ) do
        result =
          ActorLabels::StrictBatchJob.new.perform(
            limit: 1,
            persist_cursor: false
          )

        raw =
          Sidekiq.redis do |redis|
            redis.get(
              ActorLabels::StrictBatchJob::WORKER_STATUS_KEY
            )
          end

        @worker_status_payload =
          raw.present? ? JSON.parse(raw) : {}

        result
      end
    ensure
      Sidekiq.redis do |redis|
        redis.del(ActorLabels::StrictBatchJob::LOCK_KEY)
        redis.del(ActorLabels::StrictBatchJob::LAST_RUN_KEY)
        redis.del(ActorLabels::StrictBatchJob::WORKER_STATUS_KEY)
      end
    end

    def batch_result
      {
        ok: true,
        dry_run: true,
        cursor: {
          next_after_id: 0
        },
        batch: {
          scanned: 0,
          eligible: 0,
          expected_labels: 0,
          written_labels: 0,
          failed: 0
        },
        rejected_by_reason: {},
        runtime_ms: 1,
        heights: {}
      }
    end

    def with_env(values)
      old_values = {}

      values.each_key do |key|
        old_values[key] = ENV[key]
      end

      values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end

      yield
    ensure
      old_values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end

    def with_stubbed(object, method_name, value)
      original =
        object.method(method_name)

      object.define_singleton_method(method_name) do |*args, **kwargs|
        if value.respond_to?(:call)
          value.call(*args, **kwargs)
        else
          value
        end
      end

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
