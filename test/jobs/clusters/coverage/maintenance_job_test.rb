# frozen_string_literal: true

require "test_helper"
require "sidekiq/api"

module Clusters
  module Coverage
    class MaintenanceJobTest <
      ActiveJob::TestCase
      setup do
        @original_schedule_key =
          MaintenanceJob.method(:schedule_key)

        @test_schedule_key =
          "#{MaintenanceJob::SCHEDULE_KEY}:test:#{SecureRandom.hex(8)}"

        test_schedule_key = @test_schedule_key

        MaintenanceJob.define_singleton_method(:schedule_key) do
          test_schedule_key
        end

        @previous_queue_adapter =
          ActiveJob::Base.queue_adapter

        ActiveJob::Base.queue_adapter = :test
        clear_enqueued_jobs
        clear_schedule_marker
      end

      teardown do
        clear_enqueued_jobs
        clear_schedule_marker
        ActiveJob::Base.queue_adapter =
          @previous_queue_adapter

        original_schedule_key =
          @original_schedule_key

        MaintenanceJob.define_singleton_method(:schedule_key) do
          original_schedule_key.call
        end
      end

      test "is disabled by default" do
        previous =
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ]

        ENV.delete(
          "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
        )

        result =
          MaintenanceJob.perform_now(
            {
              "reschedule" => false,
              "lock" => false
            }
          )

        assert_equal true, result[:ok]
        assert_equal "disabled", result[:status]
      ensure
        if previous.nil?
          ENV.delete(
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          )
        else
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ] = previous
        end
      end

      test "a disabled scheduled job releases only its owned marker" do
        schedule_token =
          "scheduled:owned-test-token"

        Sidekiq.redis do |redis|
          redis.call(
            "SET",
            MaintenanceJob.schedule_key,
            schedule_token
          )
        end

        result = nil

        with_disabled do
          result =
            MaintenanceJob.perform_now(
              {
                "reschedule" => true,
                "lock" => true,
                "schedule_token" => schedule_token
              }
            )
        end

        assert_equal true, result[:ok]
        assert_equal "disabled", result[:status]
        assert_nil current_schedule_marker
        assert_empty enqueued_jobs
      end

      test "a disabled scheduled job preserves another owner's marker" do
        owned_token =
          "scheduled:owned-by-another-job"

        Sidekiq.redis do |redis|
          redis.call(
            "SET",
            MaintenanceJob.schedule_key,
            owned_token
          )
        end

        result = nil

        with_disabled do
          result =
            MaintenanceJob.perform_now(
              {
                "reschedule" => true,
                "lock" => true,
                "schedule_token" =>
                  "scheduled:stale-job-token"
              }
            )
        end

        assert_equal "disabled", result[:status]
        assert_equal owned_token, current_schedule_marker
        assert_empty enqueued_jobs
      end

      test "runs backfill normal coverage and reconciliation" do
        previous =
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ]

        ENV[
          "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
        ] = "1"

        backfill_calls = []
        runner_calls = []

        backfill =
          lambda do |**arguments|
            backfill_calls << arguments

            {
              ok: true,
              addresses_upserted: 4,
              from_height: 955_300,
              to_height: 955_301
            }
          end

        runner =
          lambda do |**arguments|
            runner_calls << arguments

            {
              ok: true,
              singleton_clusters_created:
                arguments[:reconcile] ? 2 : 3
            }
          end

        health = {
          status: "completed",
          address_id_lag: 0,
          null_addresses_after_cursor: 0
        }

        coverage = {
          complete: true,
          from_height: 955_300,
          to_height: 955_301
        }

        result = nil

        with_stubbed(
          InputAddressBackfill,
          :call,
          backfill
        ) do
          with_stubbed(
            AddressRunner,
            :call,
            runner
          ) do
            with_stubbed(
              AddressHealthSnapshot,
              :call,
              health
            ) do
              with_stubbed(
                OperationalSnapshot,
                :refresh,
                coverage
              ) do
                with_stubbed(
                  System::PipelineController,
                  :decision,
                  { allowed: true }
                ) do
                  result =
                    MaintenanceJob.perform_now(
                      {
                        "reschedule" => false,
                        "lock" => false
                      }
                    )
                end
              end
            end
          end
        end

        assert_equal true, result[:ok]
        assert_equal "completed", result[:status]
        assert_equal true, backfill_calls.first[:lock]
        assert_equal 2, runner_calls.size
        assert_equal false, runner_calls[0][:reconcile]
        assert_equal true, runner_calls[1][:reconcile]
        assert_equal 0, result.dig(:health, :address_id_lag)
      ensure
        if previous.nil?
          ENV.delete(
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          )
        else
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ] = previous
        end
      end

      test "a denied job schedules one retry with the requested delay" do
        decision = {
          allowed: false,
          reason: :layer1_realtime_priority,
          retry_in: 120.seconds
        }
        decision_calls = []
        now = Time.zone.parse("2026-07-23 11:30:40")

        result = nil

        with_enabled do
          with_stubbed(
            System::PipelineController,
            :decision,
            lambda do |role|
              decision_calls << role
              decision
            end
          ) do
            travel_to(now) do
              result =
                MaintenanceJob.perform_now(
                  {
                    "reschedule" => true,
                    "lock" => false
                  }
                )
            end
          end
        end

        assert_equal "skipped", result[:status]
        assert_equal decision, result[:decision]
        assert_equal [ :coverage ], decision_calls
        assert_equal 1, enqueued_jobs.size
        assert_equal MaintenanceJob, enqueued_jobs.first[:job]
        assert_equal "cluster_coverage", enqueued_jobs.first[:queue]
        assert_in_delta now.to_f + 120, enqueued_jobs.first[:at], 0.1
      end

      test "two successive enqueue requests create one job" do
        results = []

        2.times do
          results << MaintenanceJob.enqueue_once(source: "test")
        end

        assert_equal 1, enqueued_jobs.size
        assert_equal 1, results.count { |result| result[:rescheduled] }
        assert_equal 1, results.count { |result| result[:reason] == "already_scheduled" }
      end

      test "a job in the scheduled set prevents another enqueue" do
        existing =
          Struct.new(:item).new(
            { "wrapped" => MaintenanceJob.name }
          )

        with_sidekiq_sets(scheduled: [ existing ]) do
          result = MaintenanceJob.enqueue_once(source: "test")

          assert_equal false, result[:rescheduled]
          assert_equal "already_scheduled", result[:reason]
        end

        assert_empty enqueued_jobs
      end

      test "a job in the queue prevents another enqueue" do
        existing =
          Struct.new(:item).new(
            { "wrapped" => MaintenanceJob.name }
          )

        with_sidekiq_sets(queue: [ existing ]) do
          result = MaintenanceJob.enqueue_once(source: "test")

          assert_equal false, result[:rescheduled]
          assert_equal "already_scheduled", result[:reason]
        end

        assert_empty enqueued_jobs
      end

      test "recognizes structural Sidekiq and Active Job payloads" do
        payloads = [
          { "wrapped" => MaintenanceJob.name },
          { "class" => MaintenanceJob.name },
          { "job_class" => MaintenanceJob.name },
          {
            "class" =>
              "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
            "args" => [
              {
                "job_class" => MaintenanceJob.name
              }
            ]
          }
        ]

        payloads.each do |payload|
          assert MaintenanceJob.send(
            :maintenance_job?,
            payload
          )
        end
      end

      test "does not match a class name contained only in arguments" do
        payload = {
          "wrapped" => "OtherJob",
          "class" =>
            "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
          "args" => [
            {
              "job_class" => "OtherJob",
              "arguments" => [
                MaintenanceJob.name
              ]
            }
          ]
        }

        refute MaintenanceJob.send(
          :maintenance_job?,
          payload
        )
      end

      test "another active job prevents an enqueue" do
        work =
          Struct.new(:payload).new(
            { "wrapped" => MaintenanceJob.name }
          )

        with_sidekiq_sets(work: [ [ "process", "thread", work ] ]) do
          result = MaintenanceJob.enqueue_once(source: "test")

          assert_equal false, result[:rescheduled]
          assert_equal "already_scheduled", result[:reason]
        end

        assert_empty enqueued_jobs
      end

      test "concurrent enqueue requests create one job" do
        ready = Queue.new
        start = Queue.new

        threads =
          8.times.map do
            Thread.new do
              ready << true
              start.pop
              MaintenanceJob.enqueue_once(source: "concurrent_test")
            end
          end

        8.times { ready.pop }
        8.times { start << true }

        results = threads.map(&:value)

        assert_equal 1, enqueued_jobs.size
        assert_equal 1, results.count { |result| result[:rescheduled] }
        assert_equal 7, results.count { |result| result[:reason] == "already_scheduled" }
      end

      test "a duplicate exits before consulting the pipeline controller" do
        MaintenanceJob.enqueue_once(source: "test")

        with_enabled do
          with_stubbed(
            System::PipelineController,
            :decision,
            ->(*) { raise "pipeline controller must not be called" }
          ) do
            result =
              MaintenanceJob.perform_now(
                {
                  "reschedule" => true,
                  "lock" => false
                }
              )

            assert_equal "skipped", result[:status]
            assert_equal "already_scheduled", result[:reason]
          end
        end

        assert_equal 1, enqueued_jobs.size
      end

      test "the scheduled successor owns the marker and continues the chain" do
        MaintenanceJob.enqueue_once(
          wait: 120.seconds,
          source: "test"
        )

        schedule_token = current_schedule_marker
        clear_enqueued_jobs

        with_enabled do
          with_stubbed(
            System::PipelineController,
            :decision,
            {
              allowed: false,
              reason: :layer1_realtime_priority,
              retry_in: 120.seconds
            }
          ) do
            result =
              MaintenanceJob.perform_now(
                {
                  "reschedule" => true,
                  "lock" => false,
                  "schedule_token" => schedule_token
                }
              )

            assert_equal "skipped", result[:status]
            assert_equal "pipeline_controller_denied", result[:reason]
          end
        end

        assert_equal 1, enqueued_jobs.size
        assert current_schedule_marker.start_with?("scheduled:")
        refute_equal schedule_token, current_schedule_marker
      end

      private

      def clear_schedule_marker
        Sidekiq.redis do |redis|
          redis.call(
            "DEL",
            MaintenanceJob.schedule_key
          )
        end
      end

      def current_schedule_marker
        Sidekiq.redis do |redis|
          redis.call(
            "GET",
            MaintenanceJob.schedule_key
          )
        end
      end

      def with_enabled
        previous =
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ]

        ENV[
          "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
        ] = "1"

        yield
      ensure
        if previous.nil?
          ENV.delete(
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          )
        else
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ] = previous
        end
      end

      def with_disabled
        previous =
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ]

        ENV.delete(
          "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
        )

        yield
      ensure
        if previous.nil?
          ENV.delete(
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          )
        else
          ENV[
            "CLUSTER_COVERAGE_MAINTENANCE_ENABLED"
          ] = previous
        end
      end

      def with_sidekiq_sets(queue: [], scheduled: [], retries: [], work: [])
        with_stubbed(Sidekiq::Queue, :new, queue) do
          with_stubbed(Sidekiq::ScheduledSet, :new, scheduled) do
            with_stubbed(Sidekiq::RetrySet, :new, retries) do
              with_stubbed(Sidekiq::WorkSet, :new, work) do
                yield
              end
            end
          end
        end
      end

      def with_stubbed(object, method_name, value = nil)
        original = object.method(method_name)
        replacement =
          if value.respond_to?(:call)
            value
          else
            ->(*_args, **_kwargs) { value }
          end

        object.define_singleton_method(method_name, &replacement)

        yield
      ensure
        object.define_singleton_method(method_name) do |*args, **kwargs, &block|
          original.call(*args, **kwargs, &block)
        end
      end
    end
  end
end
