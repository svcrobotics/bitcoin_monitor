# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class SchedulerDevelopmentBackfillTest <
    ActiveSupport::TestCase

    test "actor profile self reschedules in development backfill mode" do
      with_pipeline_mode("development_backfill") do
        scheduler = Scheduler.new

        spec =
          Scheduler::JOBS.find do |job|
            job.name == :actor_profile
          end

        args =
          scheduler.send(
            :args_with_lease,
            spec,
            nil
          )

        assert_equal true, args.first[:reschedule]
        assert_equal false, spec.args.first[:reschedule]
      end
    end

    test "actor profile remains scheduler driven in realtime mode" do
      with_pipeline_mode("realtime") do
        scheduler = Scheduler.new

        spec =
          Scheduler::JOBS.find do |job|
            job.name == :actor_profile
          end

        args =
          scheduler.send(
            :args_with_lease,
            spec,
            nil
          )

        assert_equal false, args.first[:reschedule]
      end
    end

    private

    def with_pipeline_mode(mode)
      previous =
        ENV.key?("TANSA_PIPELINE_MODE") ?
          ENV["TANSA_PIPELINE_MODE"] :
          :missing

      ENV["TANSA_PIPELINE_MODE"] = mode

      yield
    ensure
      if previous == :missing
        ENV.delete("TANSA_PIPELINE_MODE")
      else
        ENV["TANSA_PIPELINE_MODE"] = previous
      end
    end
  end
end
