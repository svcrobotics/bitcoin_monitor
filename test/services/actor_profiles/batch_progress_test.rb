# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class BatchProgressTest <
    ActiveSupport::TestCase

    def setup
      BatchProgress.clear!
    end

    def teardown
      BatchProgress.clear!
    end

    test "tracks a running batch incrementally" do
      assert BatchProgress.start!(
        token: "token-a",
        requested_limit: 25
      )

      started =
        BatchProgress.read

      assert_equal "running", started[:status]
      assert_equal 25, started[:requested_limit]
      assert_equal 0, started[:processed]
      assert_equal 0, started[:built]

      assert BatchProgress.update!(
        token: "token-a",
        selected: 25,
        processed: 3,
        built: 2,
        deferred: 1,
        failed: 0,
        current_cluster_id: 60704,
        elapsed_ms: 125_000
      )

      current =
        BatchProgress.read

      assert_equal 25, current[:selected]
      assert_equal 3, current[:processed]
      assert_equal 2, current[:built]
      assert_equal 1, current[:deferred]
      assert_equal 60704, current[:current_cluster_id]
      assert_equal 125_000, current[:elapsed_ms]
      refute current.key?(:token)
    end

    test "rejects updates from another token" do
      BatchProgress.start!(
        token: "token-a",
        requested_limit: 25
      )

      refute BatchProgress.update!(
        token: "token-b",
        processed: 10
      )

      assert_equal(
        0,
        BatchProgress.read[:processed]
      )
    end

    test "only owner token can clear progress" do
      BatchProgress.start!(
        token: "token-a",
        requested_limit: 25
      )

      refute BatchProgress.clear!(
        token: "token-b"
      )

      assert_not_nil BatchProgress.read

      assert BatchProgress.clear!(
        token: "token-a"
      )

      assert_nil BatchProgress.read
    end
  end
end
