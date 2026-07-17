# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class StrictIoLeaseTest < ActiveSupport::TestCase
    setup do
      StrictIoLease.clear!
    end

    teardown do
      StrictIoLease.clear!
    end

    test "default ttl is fifteen minutes and independent from cluster slice runtime" do
      assert_equal 900, StrictIoLease::DEFAULT_TTL_SECONDS
      assert_equal 900, StrictIoLease.ttl_seconds_default
      assert_equal 90, Clusters::StrictTipSyncJob::MAX_SLICE_SECONDS
    end

    test "never grants two simultaneous owners" do
      layer1 =
        StrictIoLease.acquire("layer1")

      cluster =
        StrictIoLease.acquire("cluster")

      assert layer1
      assert_nil cluster

      current =
        StrictIoLease.current

      assert_equal "layer1", current.owner
      assert_equal layer1.token, current.token
    end

    test "grants the dedicated cluster transaction projection owner" do
      lease =
        StrictIoLease.acquire("cluster_transaction_projection")

      assert lease
      assert_equal "cluster_transaction_projection", StrictIoLease.current.owner

      assert(
        StrictIoLease.release(
          owner: "cluster_transaction_projection",
          token: lease.token
        )
      )
    end

    test "expired lease is recoverable after worker crash" do
      layer1 =
        StrictIoLease.acquire("layer1")

      assert layer1

      Sidekiq.redis do |redis|
        redis.hset(
          StrictIoLease::KEY,
          "expires_at_ms",
          ((2.minutes.ago).to_f * 1000).round
        )
        redis.persist(StrictIoLease::KEY)
      end

      cluster =
        StrictIoLease.acquire("cluster")

      assert cluster
      assert_equal "cluster", StrictIoLease.current.owner
    end

    test "wrong token cannot release lease" do
      lease =
        StrictIoLease.acquire("layer1")

      refute(
        StrictIoLease.release(
          owner: "layer1",
          token: "wrong-token"
        )
      )

      assert_equal lease.token, StrictIoLease.current.token

      assert(
        StrictIoLease.release(
          owner: "layer1",
          token: lease.token
        )
      )

      assert_nil StrictIoLease.current
    end

    test "renewal requires matching owner and token" do
      lease =
        StrictIoLease.acquire("cluster")

      assert(
        StrictIoLease.renew(
          owner: "cluster",
          token: lease.token
        )
      )

      refute(
        StrictIoLease.renew(
          owner: "cluster",
          token: "wrong-token"
        )
      )

      refute(
        StrictIoLease.renew(
          owner: "layer1",
          token: lease.token
        )
      )

      current =
        StrictIoLease.current

      assert_equal "cluster", current.owner
      assert_equal lease.token, current.token
    end
  end
end
