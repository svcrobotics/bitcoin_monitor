# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class StrictBatchBuilderTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      cleanup_records

      @height = 955_400

      BlockBufferModel.create!(
        height: @height,
        block_hash: unique_hash("layer1"),
        status: "processed",
        processed_at: Time.current
      )

      ClusterProcessedBlock.create!(
        height: @height,
        block_hash: unique_hash("cluster"),
        status: "processed",
        processed_at: Time.current
      )
    end

    def teardown
      cleanup_records
    end

    test "selects legacy and stale profiles but not valid strict core profile" do
      strict_v1 = profiled_cluster(profile_version: "strict_v1")
      strict_v2 = profiled_cluster(profile_version: "strict_v2")
      without_version = profiled_cluster(profile_version: nil)
      valid_v3 = profiled_cluster(profile_version: "strict_v3_core")
      dirty_v3 = profiled_cluster(profile_version: "strict_v3_core", dirty: true)
      mismatch_v3 =
        profiled_cluster(
          profile_version: "strict_v3_core",
          profile_composition_version: 1,
          cluster_composition_version: 2
        )

      selected_ids = next_cluster_ids

      assert_includes selected_ids, strict_v1.id
      assert_includes selected_ids, strict_v2.id
      assert_includes selected_ids, without_version.id
      refute_includes selected_ids, valid_v3.id
      assert_includes selected_ids, dirty_v3.id
      assert_includes selected_ids, mismatch_v3.id
    end

    test "prioritizes stale multi address profiles before missing multi address clusters" do
      missing = cluster_with_addresses(address_count: 2)
      stale = profiled_cluster(profile_version: "strict_v2")

      selected_ids = next_cluster_ids(limit: 2)

      assert_equal [stale.id, missing.id], selected_ids
    end

    test "excludes singleton missing clusters without explicit opt in" do
      singleton = cluster_with_addresses(address_count: 1)
      multi = cluster_with_addresses(address_count: 2)

      selected_ids = next_cluster_ids(limit: 10)

      refute_includes selected_ids, singleton.id
      assert_includes selected_ids, multi.id
    end

    test "includes singleton missing clusters with explicit opt in" do
      singleton = cluster_with_addresses(address_count: 1)

      selected_ids =
        with_singleton_opt_in do
          next_cluster_ids(limit: 10)
        end

      assert_includes selected_ids, singleton.id
    end

    private

    def next_cluster_ids(limit: 10)
      ActorProfiles::StrictBatchBuilder
        .new(limit: limit)
        .send(:next_cluster_ids)
    end

    def profiled_cluster(
      profile_version:,
      dirty: false,
      profile_composition_version: 1,
      cluster_composition_version: 1
    )
      cluster =
        cluster_with_addresses(
          address_count: 2,
          composition_version: cluster_composition_version
        )

      traits = {}
      traits["profile_version"] = profile_version if profile_version

      metadata = {
        "strict" => true,
        "historical_enrichment_status" => "missing"
      }

      ActorProfile.create!(
        cluster: cluster,
        balance_btc: "1.0",
        total_received_btc: nil,
        total_sent_btc: "0.1",
        net_btc: "1.0",
        tx_count: 1,
        inflow_count: nil,
        outflow_count: 1,
        dirty: dirty,
        last_computed_height: cluster.last_seen_height,
        cluster_composition_version: profile_composition_version,
        traits: traits,
        metadata: metadata
      )

      cluster
    end

    def cluster_with_addresses(
      address_count:,
      composition_version: 1
    )
      cluster =
        Cluster.create!(
          address_count: address_count,
          first_seen_height: @height - 10,
          last_seen_height: @height - 1,
          composition_version: composition_version
        )

      address_count.times do |index|
        Address.create!(
          address: "strict-batch-#{index}-#{SecureRandom.hex(8)}",
          cluster: cluster
        )
      end

      cluster
    end

    def with_singleton_opt_in
      previous =
        ENV["ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS"]

      ENV["ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS"] = "true"
      yield
    ensure
      if previous.nil?
        ENV.delete("ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS")
      else
        ENV["ACTOR_PROFILE_STRICT_INCLUDE_SINGLETONS"] = previous
      end
    end

    def unique_hash(prefix)
      Digest::SHA256.hexdigest(
        "#{prefix}-#{SecureRandom.hex(16)}"
      )
    end

    def cleanup_records
      ActorLabel.delete_all
      ActorProfile.delete_all
      Address.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
