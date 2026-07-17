# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    class ServiceBatchJobTest <
      ActiveJob::TestCase

      test "calls exactly one service batch" do
        calls = 0
        received = nil

        implementation =
          lambda do |**arguments|
            calls += 1
            received =
              arguments

            batch_result
          end

        with_stubbed(
          Service::Batch,
          :call,
          implementation
        ) do
          result =
            ServiceBatchJob
              .new
              .perform(
                limit:
                  3,
                trigger:
                  "test",
                distribution_window_blocks:
                  600,
                distribution_chunk_size:
                  75,
                minimum_height_delta:
                  700,
                to_height:
                  1_000
              )

          assert_equal(
            1,
            calls
          )

          assert_equal(
            {
              limit: 3,
              trigger: "test",
              distribution_window_blocks: 600,
              distribution_chunk_size: 75,
              minimum_height_delta: 700,
              to_height: 1_000
            },
            received
          )

          assert_equal(
            "completed",
            result[:status]
          )
        end
      end

      test "uses the existing heavy worker queue" do
        assert_equal(
          "actor_behavior_heavy",
          ServiceBatchJob.queue_name
        )
      end

      test "returns a shadow result without label publication" do
        with_stubbed(
          Service::Batch,
          :call,
          batch_result
        ) do
          result =
            ServiceBatchJob
              .new
              .perform

          assert_equal(
            "service_infrastructure",
            result[:analysis_kind]
          )

          assert_equal(
            true,
            result[:shadow_mode]
          )

          assert_equal(
            false,
            result[:labels_enabled]
          )

          assert_equal(
            0,
            result[:labels_synchronized]
          )

          assert_equal(
            0,
            result[:label_sync_failed]
          )
        end
      end

      test "does not schedule itself or call label writers" do
        source =
          Rails.root.join(
            "app/jobs/actor_behaviors/heavy/",
            "service_batch_job.rb"
          ).read

        refute_match(
          /perform_later/,
          source
        )

        refute_match(
          /perform_async/,
          source
        )

        refute_match(
          /perform_in/,
          source
        )

        refute_match(
          /HeavyWriter/,
          source
        )

        refute_match(
          /ActorLabel/,
          source
        )

        refute_match(
          /StrictPipeline::Scheduler/,
          source
        )
      end

      private

      def batch_result
        {
          ok: true,
          status: "completed",

          batch_version:
            Service::Batch::VERSION,

          analysis_kind:
            Service::Contract::
              ANALYSIS_KIND,

          shadow_mode:
            true,

          trigger:
            "test",

          labels_enabled:
            false,

          selected:
            1,

          certified:
            1,

          deferred:
            0,

          failed:
            0,

          created:
            1,

          updated:
            0,

          unchanged:
            0,

          labels_synchronized:
            0,

          label_sync_failed:
            0,

          label_sync_skipped:
            1,

          duration_seconds:
            0.1,

          results: []
        }
      end

      def with_stubbed(
        object,
        method_name,
        replacement
      )
        singleton =
          object.singleton_class

        original =
          singleton.instance_method(
            method_name
          )

        singleton.send(
          :define_method,
          method_name
        ) do |*arguments, **keywords, &block|
          if replacement.respond_to?(
            :call
          )
            replacement.call(
              *arguments,
              **keywords,
              &block
            )
          else
            replacement
          end
        end

        yield
      ensure
        singleton.send(
          :define_method,
          method_name,
          original
        )
      end
    end
  end
end
