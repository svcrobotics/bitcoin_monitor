# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class SlowProfileQuarantineTest <
        ActiveSupport::TestCase
    def setup
      ActorProfiles::
        SlowProfileQuarantine
        .clear_all!
    end

    def teardown
      ActorProfiles::
        SlowProfileQuarantine
        .clear_all!
    end

    test "quarantines a cluster until its retry date" do
      now =
        Time.zone.parse(
          "2026-07-10 10:00:00"
        )

      record =
        ActorProfiles::
          SlowProfileQuarantine
          .quarantine!(
            cluster_id: 42,
            reason: "profile_timeout",
            runtime_ms: 120_000,
            now: now
          )

      assert_equal 42, record[:cluster_id]
      assert_equal 1, record[:attempts]
      assert_equal 1_800,
                   record[:retry_delay_seconds]

      assert_includes(
        ActorProfiles::
          SlowProfileQuarantine
          .active_cluster_ids(
            now: now + 1.second
          ),
        42
      )

      refute_includes(
        ActorProfiles::
          SlowProfileQuarantine
          .active_cluster_ids(
            now: now + 1_801.seconds
          ),
        42
      )
    end

    test "increases retry delay after repeated attempts" do
      now =
        Time.zone.parse(
          "2026-07-10 10:00:00"
        )

      ActorProfiles::
        SlowProfileQuarantine
        .quarantine!(
          cluster_id: 99,
          reason: "profile_timeout",
          now: now
        )

      second =
        ActorProfiles::
          SlowProfileQuarantine
          .quarantine!(
            cluster_id: 99,
            reason: "profile_timeout",
            now: now + 10.seconds
          )

      assert_equal 2, second[:attempts]
      assert_equal 3_600,
                   second[:retry_delay_seconds]
    end

    test "clear removes quarantine and metadata" do
      ActorProfiles::
        SlowProfileQuarantine
        .quarantine!(
          cluster_id: 123,
          reason: "slow_runtime"
        )

      assert(
        ActorProfiles::
          SlowProfileQuarantine
          .metadata_for(123)
          .present?
      )

      ActorProfiles::
        SlowProfileQuarantine
        .clear!(123)

      assert_equal(
        {},
        ActorProfiles::
          SlowProfileQuarantine
          .metadata_for(123)
      )
    end
  end
end
