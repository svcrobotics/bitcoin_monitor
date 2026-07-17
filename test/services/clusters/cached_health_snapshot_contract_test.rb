# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class CachedHealthSnapshotContractTest <
    ActiveSupport::TestCase

    test "refreshes and stores snapshot on cache miss" do
      cache =
        ActiveSupport::Cache::MemoryStore.new

      calls = 0
      fresh = valid_snapshot

      Rails.stub(
        :cache,
        cache
      ) do
        Clusters::HealthSnapshot.stub(
          :call,
          lambda {
            calls += 1
            fresh
          }
        ) do
          first =
            CachedHealthSnapshot.read

          second =
            CachedHealthSnapshot.read

          assert_equal fresh, first
          assert_equal fresh, second
          assert_equal 1, calls

          assert_equal(
            fresh,
            cache.read(
              CachedHealthSnapshot::CACHE_KEY
            )
          )
        end
      end
    end

    test "rejects snapshot using an old contract" do
      cache =
        ActiveSupport::Cache::MemoryStore.new

      old_snapshot = {
        source:
          "cluster_operational_snapshot",

        sync: {},
        counts: {}
      }

      fresh =
        valid_snapshot

      cache.write(
        CachedHealthSnapshot::CACHE_KEY,
        old_snapshot
      )

      Rails.stub(
        :cache,
        cache
      ) do
        Clusters::HealthSnapshot.stub(
          :call,
          fresh
        ) do
          assert_equal(
            fresh,
            CachedHealthSnapshot.read
          )
        end
      end
    end

    test "missing audit does not claim four conformant checks" do
      service =
        DashboardSnapshot.new(
          snapshot: {
            audit: {}
          }
        )

      proof =
        service.send(
          :proof_snapshot,
          {
            cluster_tip: 100
          }
        )

      assert proof[:pending]
      assert_empty proof[:checks]
      assert_equal 0, proof[:passed_checks]
      assert_equal 0, proof[:total_checks]
      assert_nil proof[:compliance]
    end

    private

    def valid_snapshot
      {
        source:
          "cluster_strict_health_snapshot",

        generated_at:
          Time.current,

        status:
          "healthy",

        sync: {
          layer1_tip: 100,
          cluster_tip: 100
        },

        counts: {
          clusters: 12,
          addresses: 25,
          cluster_inputs: 40
        },

        audit: {
          status: "healthy",
          heights: [100]
        },

        automation: {
          queue_size: 0
        }
      }
    end
  end
end
