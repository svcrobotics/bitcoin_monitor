# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class SchedulerAddressSpendProjectionTest <
    ActiveSupport::TestCase

    test "places projection before ActorProfile" do
      jobs =
        Scheduler::JOBS

      names =
        jobs.map(&:name)

      projection_index =
        names.index(
          :address_spend_projection
        )

      profile_index =
        names.index(
          :actor_profile
        )

      assert projection_index
      assert profile_index

      assert_operator(
        projection_index,
        :<,
        profile_index
      )
    end

    test "uses an isolated ActiveJob queue" do
      spec =
        Scheduler::JOBS.find do |job|
          job.name ==
            :address_spend_projection
        end

      assert_equal(
        "address_spend_projection",
        spec.queue
      )

      assert_equal(
        "AddressSpendStats::ProjectionJob",
        spec.klass
      )

      assert_equal(
        :active_job,
        spec.kind
      )
    end

    test "does not own strict io" do
      refute_includes(
        Scheduler::STRICT_IO_ROLES,
        :address_spend_projection
      )
    end
  end
end
