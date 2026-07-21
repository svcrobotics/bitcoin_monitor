# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class StrictIoLeaseTest < ActiveSupport::TestCase
    setup do
      @previous_mode = ENV[StrictIoMode::ENV_KEY]
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::SERIALIZED
      StrictIoLease.clear!
    end

    teardown do
      StrictIoLease.clear!
      if @previous_mode.nil?
        ENV.delete(StrictIoMode::ENV_KEY)
      else
        ENV[StrictIoMode::ENV_KEY] = @previous_mode
      end
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

    test "concurrent ssd grants layer1 and cluster together" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      layer1 = StrictIoLease.acquire("layer1")
      cluster = StrictIoLease.acquire("cluster")

      assert layer1
      assert cluster
      assert_equal %w[layer1 cluster], StrictIoLease.currents.map(&:owner)
      assert StrictIoLease.owned_by?("layer1")
      assert StrictIoLease.owned_by?("cluster")
    end

    test "concurrent ssd refuses two layer1 leases" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert StrictIoLease.acquire("layer1")
      assert_nil StrictIoLease.acquire("layer1")
    end

    test "concurrent ssd refuses two cluster leases" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert StrictIoLease.acquire("cluster")
      assert_nil StrictIoLease.acquire("cluster")
    end

    test "projection is refused while layer1 and cluster leases are active" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert StrictIoLease.acquire("layer1")
      assert StrictIoLease.acquire("cluster")

      assert_nil StrictIoLease.acquire("cluster_transaction_projection")
    end

    test "layer1 and cluster are refused while projection lease is active" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert StrictIoLease.acquire("cluster_transaction_projection")

      assert_nil StrictIoLease.acquire("layer1")
      assert_nil StrictIoLease.acquire("cluster")
    end

    test "release keeps compatible lease and requires matching owner token" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      layer1 = StrictIoLease.acquire("layer1")
      cluster = StrictIoLease.acquire("cluster")

      refute StrictIoLease.release(owner: "layer1", token: cluster.token)
      assert StrictIoLease.release(owner: "layer1", token: layer1.token)

      assert_equal ["cluster"], StrictIoLease.currents.map(&:owner)
      assert StrictIoLease.renew(owner: "cluster", token: cluster.token)
    end

    test "concurrent ssd refuses a live serialized lease" do
      assert StrictIoLease.acquire("layer1")

      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert_nil StrictIoLease.acquire("cluster")
    end

    test "serialized refuses live concurrent ssd leases" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert StrictIoLease.acquire("layer1")
      assert StrictIoLease.acquire("cluster")

      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::SERIALIZED

      assert_nil StrictIoLease.acquire("cluster_transaction_projection")
    end

    test "owners expire independently while the redis key remains alive" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      layer1 = StrictIoLease.acquire("layer1", ttl_seconds: 60)
      cluster = StrictIoLease.acquire("cluster", ttl_seconds: 30)

      assert layer1
      assert cluster

      expire_concurrent_owner!("cluster")

      assert(
        StrictIoLease.renew(
          owner: "layer1",
          token: layer1.token,
          ttl_seconds: 120
        )
      )

      assert_operator redis_key_ttl_ms, :>, 0
      assert_equal ["layer1"], StrictIoLease.currents.map(&:owner)
      refute concurrent_owner_field?("cluster", "token")
      refute StrictIoLease.renew(owner: "cluster", token: cluster.token)

      reacquired_cluster = StrictIoLease.acquire("cluster")

      assert reacquired_cluster
      assert_nil StrictIoLease.acquire("cluster_transaction_projection")

      assert StrictIoLease.release(owner: "layer1", token: layer1.token)
      assert_equal ["cluster"], StrictIoLease.currents.map(&:owner)
      assert_nil StrictIoLease.acquire("cluster_transaction_projection")

      assert(
        StrictIoLease.release(
          owner: "cluster",
          token: reacquired_cluster.token
        )
      )

      assert StrictIoLease.acquire("cluster_transaction_projection")
    end

    test "projection acquires after every concurrent owner expires" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert StrictIoLease.acquire("layer1")
      assert StrictIoLease.acquire("cluster")

      expire_concurrent_owner!("layer1")
      expire_concurrent_owner!("cluster")

      projection = StrictIoLease.acquire("cluster_transaction_projection")

      assert projection
      assert_equal ["cluster_transaction_projection"],
        StrictIoLease.currents.map(&:owner)
    end

    test "wrong token cannot mutate either concurrent owner" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      layer1 = StrictIoLease.acquire("layer1")
      cluster = StrictIoLease.acquire("cluster")

      refute StrictIoLease.renew(owner: "layer1", token: cluster.token)
      refute StrictIoLease.release(owner: "layer1", token: cluster.token)
      refute StrictIoLease.renew(owner: "cluster", token: layer1.token)
      refute StrictIoLease.release(owner: "cluster", token: layer1.token)

      assert_equal(
        {
          "layer1" => layer1.token,
          "cluster" => cluster.token
        },
        StrictIoLease.currents.to_h { |lease| [lease.owner, lease.token] }
      )
    end

    test "lua acquisition is atomic for competing identical owners" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      leases = race_acquisitions("layer1", "layer1")

      assert_equal 1, leases.compact.size
      assert_equal ["layer1"], StrictIoLease.currents.map(&:owner)
    end

    test "lua acquisition atomically permits only compatible combinations" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      compatible = race_acquisitions("layer1", "cluster")

      assert compatible.all?
      assert_equal %w[layer1 cluster], StrictIoLease.currents.map(&:owner)

      StrictIoLease.clear!

      incompatible =
        race_acquisitions("layer1", "cluster_transaction_projection")

      assert_equal 1, incompatible.compact.size
      assert_equal 1, StrictIoLease.currents.size
      refute_equal(
        %w[layer1 cluster_transaction_projection].sort,
        StrictIoLease.currents.map(&:owner).sort
      )
    end

    private

    def expire_concurrent_owner!(owner)
      expired_at = 2.seconds.ago

      Sidekiq.redis do |redis|
        redis.hset(
          StrictIoLease::KEY,
          "#{owner}:expires_at",
          expired_at.iso8601(6),
          "#{owner}:expires_at_ms",
          (expired_at.to_f * 1000).round
        )
      end
    end

    def concurrent_owner_field?(owner, suffix)
      Sidekiq.redis do |redis|
        redis
          .hexists(StrictIoLease::KEY, "#{owner}:#{suffix}")
          .to_i
          .positive?
      end
    end

    def redis_key_ttl_ms
      Sidekiq.redis do |redis|
        redis.pttl(StrictIoLease::KEY)
      end
    end

    def race_acquisitions(*owners)
      ready = Queue.new
      start = Queue.new

      threads =
        owners.map do |owner|
          Thread.new do
            ready << true
            start.pop
            StrictIoLease.acquire(owner)
          end
        end

      owners.size.times { ready.pop }
      owners.size.times { start << true }

      threads.map(&:value)
    end
  end
end
