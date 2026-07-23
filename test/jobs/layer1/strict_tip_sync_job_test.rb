# frozen_string_literal: true

require "test_helper"

module Layer1
  class StrictTipSyncJobTest < ActiveSupport::TestCase
    test "successful block with backlog requests post completion scheduler handoff" do
      requests = []
      events = []
      job =
        Layer1::StrictTipSyncJob.new

      with_layer1_lease_granted(events: events) do
        with_stubbed(
          Layer1::StrictTipSyncer,
          :call,
          {
            ok: true,
            status: "synced_segment",
            best_height: 102,
            continuous_tip: 101,
            processed: 1
          }
        ) do
          with_stubbed(
            StrictPipeline::SchedulerWakeup,
            :request!,
            lambda do |**kwargs|
              events << :wakeup_requested
              requests << kwargs
              { enqueued: true }
            end
          ) do
            with_object_stubbed(
              job,
              :fresh_bitcoin_core_height,
              102
            ) do
              with_object_stubbed(
                job,
                :fresh_layer1_processed_height,
                101
              ) do
                result =
                  job.perform("lease-token")

                assert_equal true, result[:ok]
              end
            end
          end
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_block_completed_with_backlog",
                   requests.first[:reason]
      assert_equal 2, requests.first[:wait].to_i
      assert_equal [
        :strict_io_released,
        :wakeup_requested
      ], events
    end

    test "successful final available block hands off to scheduler" do
      requests = []
      job =
        Layer1::StrictTipSyncJob.new

      with_layer1_lease_granted do
        with_stubbed(
          Layer1::StrictTipSyncer,
          :call,
          {
            ok: true,
            status: "caught_up",
            best_height: 102,
            continuous_tip: 102,
            processed: 0
          }
        ) do
          with_stubbed(
            StrictPipeline::SchedulerWakeup,
            :request!,
            lambda do |**kwargs|
              requests << kwargs
              { enqueued: true }
            end
          ) do
            with_object_stubbed(
              job,
              :fresh_bitcoin_core_height,
              102
            ) do
              with_object_stubbed(
                job,
                :fresh_layer1_processed_height,
                102
              ) do
                result =
                  job.perform("lease-token")

                assert_equal true, result[:ok]
              end
            end
          end
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_caught_up",
                   requests.first[:reason]
      assert_equal 2, requests.first[:wait].to_i
    end

    test "fresh height error uses complete fallback with positive lag" do
      requests = []
      job =
        Layer1::StrictTipSyncJob.new

      with_successful_sync(
        job: job,
        requests: requests,
        best_height: 102,
        continuous_tip: 101
      ) do
        with_object_stubbed(
          job,
          :fresh_bitcoin_core_height,
          ->(**_kwargs) { raise RuntimeError, "rpc unavailable" }
        ) do
          job.perform("lease-token")
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_block_completed_with_backlog",
                   requests.first[:reason]
      assert_equal 2, requests.first[:wait].to_i
    end

    test "fresh height error uses complete fallback with zero lag" do
      requests = []
      job =
        Layer1::StrictTipSyncJob.new

      with_successful_sync(
        job: job,
        requests: requests,
        best_height: 102,
        continuous_tip: 102
      ) do
        with_object_stubbed(
          job,
          :fresh_bitcoin_core_height,
          103
        ) do
          with_object_stubbed(
            job,
            :fresh_layer1_processed_height,
            ->(**_kwargs) { raise RuntimeError, "checkpoint unavailable" }
          ) do
            job.perform("lease-token")
          end
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_caught_up",
                   requests.first[:reason]
      assert_equal 2, requests.first[:wait].to_i
    end

    test "unknown heights request safety wakeup without caught up log" do
      requests = []
      log_messages = []
      job =
        Layer1::StrictTipSyncJob.new

      with_successful_sync(
        job: job,
        requests: requests,
        best_height: nil,
        continuous_tip: nil
      ) do
        with_object_stubbed(
          job,
          :fresh_bitcoin_core_height,
          ->(**_kwargs) { raise RuntimeError, "rpc unavailable" }
        ) do
          with_stubbed(
            Rails.logger,
            :info,
            ->(message) { log_messages << message }
          ) do
            catchup =
              job.send(
                :layer1_catchup_state,
                {
                  best_height: nil,
                  continuous_tip: nil
                }
              )

            assert_equal false, catchup[:known]
            assert_nil catchup[:lag]

            job.perform("lease-token")
          end
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_catchup_state_unknown",
                   requests.first[:reason]
      assert_equal 30, requests.first[:wait].to_i
      refute log_messages.any? { |message| message.include?("state=caught_up") }
    end

    test "non successful result requests deferred scheduler wakeup" do
      requests = []

      with_layer1_lease_granted do
        with_stubbed(
          Layer1::StrictTipSyncer,
          :call,
          {
            ok: false,
            status: "locked",
            message: "locked"
          }
        ) do
          with_stubbed(
            StrictPipeline::SchedulerWakeup,
            :request!,
            lambda do |**kwargs|
              requests << kwargs
              { enqueued: true }
            end
          ) do
            result =
              Layer1::StrictTipSyncJob
                .new
                .perform("lease-token")

            assert_equal false, result[:ok]
          end
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_failed",
                   requests.first[:reason]
      assert_equal 30, requests.first[:wait].to_i
    end

    test "exception requests deferred scheduler wakeup and reraises" do
      requests = []

      with_layer1_lease_granted do
        with_stubbed(
          Layer1::StrictTipSyncer,
          :call,
          ->(**_kwargs) { raise RuntimeError, "boom" }
        ) do
          with_stubbed(
            StrictPipeline::SchedulerWakeup,
            :request!,
            lambda do |**kwargs|
              requests << kwargs
              { enqueued: true }
            end
          ) do
            assert_raises(RuntimeError) do
              Layer1::StrictTipSyncJob
                .new
                .perform("lease-token")
            end
          end
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_failed",
                   requests.first[:reason]
      assert_equal 30, requests.first[:wait].to_i
    end

    test "strict window rebuilder does not request scheduler directly" do
      source =
        Rails
          .root
          .join(
            "app/services/layer1/strict_window_rebuilder.rb"
          )
          .read

      refute_match(
        /StrictPipeline::SchedulerWakeup\.request!/,
        source
      )
    end

    private

    def with_successful_sync(
      job:,
      requests:,
      best_height:,
      continuous_tip:
    )
      with_layer1_lease_granted do
        with_stubbed(
          Layer1::StrictTipSyncer,
          :call,
          {
            ok: true,
            status: "synced_segment",
            best_height: best_height,
            continuous_tip: continuous_tip,
            processed: 1
          }
        ) do
          with_stubbed(
            StrictPipeline::SchedulerWakeup,
            :request!,
            lambda do |**kwargs|
              requests << kwargs
              { enqueued: true }
            end
          ) do
            yield
          end
        end
      end
    end

    def with_layer1_lease_granted(events: nil)
      with_stubbed(
        StrictPipeline::StrictIoLease,
        :renew,
        true
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :release,
          lambda do |**_kwargs|
            events << :strict_io_released if events
            true
          end
        ) do
          yield
        end
      end
    end

    def with_stubbed(object, method_name, value)
      original =
        object.method(method_name)

      replacement =
        value.respond_to?(:call) ? value : ->(*_args, **_kwargs) { value }

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def with_object_stubbed(object, method_name, value)
      singleton =
        class << object
          self
        end

      had_method =
        singleton.method_defined?(method_name) ||
        singleton.private_method_defined?(method_name)

      original =
        object.method(method_name) if had_method

      replacement =
        value.respond_to?(:call) ? value : ->(*_args, **_kwargs) { value }

      singleton.define_method(method_name, &replacement)

      yield
    ensure
      if had_method
        singleton.define_method(method_name) do |*args, **kwargs, &block|
          original.call(*args, **kwargs, &block)
        end
      else
        singleton.remove_method(method_name)
      end
    end
  end
end
