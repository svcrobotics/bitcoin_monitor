# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module AddressSpendStats
  class ProjectionJobTest <
    ActiveJob::TestCase

    setup do
      @original_decision = System::PipelineController.method(:decision)
      System::PipelineController.define_singleton_method(:decision) { |_| { allowed: true } }
    end

    teardown do
      original = @original_decision
      System::PipelineController.define_singleton_method(:decision) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    test "uses the isolated projection queue" do
      assert_equal(
        "actor_profile_strict",
        ProjectionJob.queue_name
      )
    end

    test "passes bounded options to the runner" do
      captured = nil

      runner_result = {
        ok: true,
        stopped_reason:
          "limit_reached",
        projected_blocks: 20,
        idempotent_blocks: 0,
        input_count: 100,
        address_count: 80,
        total_sent_sats:
          125_000_000,
        first_height: 100,
        last_height: 119
      }

      runner =
        lambda do |**arguments|
          captured = arguments
          runner_result
        end

      result = nil

      AddressSpendStats::Runner.stub(
        :call,
        runner
      ) do
        result =
          ProjectionJob
            .new
            .perform(
              {
                "limit" => 500,
                "max_runtime_seconds" =>
                  500
              }
            )
      end

      assert_equal(
        {
          limit:
            ProjectionJob::MAX_LIMIT,
          max_runtime_seconds:
            ProjectionJob::
              MAX_RUNTIME_SECONDS,
          lock: true
        },
        captured
      )

      assert_equal(
        "completed",
        result[:status]
      )

      assert_equal(
        "actor_profile_strict",
        result.dig(
          :automation,
          :queue
        )
      )

      assert_equal false,
                   result.dig(
                     :automation,
                     :reschedule
                   )
    end

    test "returns a skip when the runner is already active" do
      runner_result = {
        ok: false,
        locked: false,
        stopped_reason:
          "already_running",
        projected_blocks: 0,
        input_count: 0,
        address_count: 0,
        total_sent_sats: 0
      }

      result = nil

      AddressSpendStats::Runner.stub(
        :call,
        runner_result
      ) do
        result =
          ProjectionJob
            .new
            .perform(
              {
                "limit" => 2,
                "max_runtime_seconds" =>
                  15
              }
            )
      end

      assert_equal(
        "skipped",
        result[:status]
      )

      assert_equal(
        "already_running",
        result[:reason]
      )
    end

    test "raises when the runner reports an error" do
      runner_result = {
        ok: false,
        stopped_reason: "error",
        failed_height: 1_700_001,
        error_class:
          "AddressSpendStats::ProjectBlock::MissingAddress",
        error_message:
          "Missing Address rows"
      }

      error =
        assert_raises(
          RuntimeError
        ) do
          AddressSpendStats::Runner.stub(
            :call,
            runner_result
          ) do
            ProjectionJob
              .new
              .perform
          end
        end

      assert_match(
        "AddressSpend projection failed",
        error.message
      )

      assert_match(
        "height=1700001",
        error.message
      )

      assert_match(
        "MissingAddress",
        error.message
      )
    end

    test "falls back to defaults for invalid options" do
      captured = nil

      runner =
        lambda do |**arguments|
          captured = arguments

          {
            ok: true,
            stopped_reason:
              "empty_queue",
            projected_blocks: 0,
            idempotent_blocks: 0,
            input_count: 0,
            address_count: 0,
            total_sent_sats: 0,
            first_height: nil,
            last_height: nil
          }
        end

      AddressSpendStats::Runner.stub(
        :call,
        runner
      ) do
        ProjectionJob
          .new
          .perform(
            {
              "limit" => "invalid",
              "max_runtime_seconds" =>
                "invalid"
            }
          )
      end

      assert_equal(
        ProjectionJob::DEFAULT_LIMIT,
        captured[:limit]
      )

      assert_equal(
        ProjectionJob::
          DEFAULT_MAX_RUNTIME_SECONDS,
        captured[
          :max_runtime_seconds
        ]
      )

      assert_equal true,
                   captured[:lock]
    end

    test "fails closed before the runner when Gate refuses or fails" do
      System::PipelineController.define_singleton_method(:decision) { |_| { allowed: false } }
      AddressSpendStats::Runner.stub(:call, ->(**) { flunk "must not run" }) do
        assert_equal "pipeline_controller_refused", ProjectionJob.new.perform[:reason]
      end

      error = RuntimeError.new("gate unavailable")
      System::PipelineController.define_singleton_method(:decision) { |_| raise error }
      AddressSpendStats::Runner.stub(:call, ->(**) { flunk "must not run" }) do
        assert_same error, assert_raises(RuntimeError) { ProjectionJob.new.perform }
      end
    end
  end
end
