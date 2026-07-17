# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

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

      ActorProfileCertificationEpoch.create!(
        profile_version:
          ActorProfiles::
            StrictBuildFromCluster::
            PROFILE_VERSION,

        start_height:
          @height - 1,

        activated_at:
          Time.current,

        source:
          ActorProfileCertificationEpoch::
            SOURCE_CLUSTER_STRICT_CHECKPOINT,

        metadata: {}
      )
    end

    def teardown
      ActorProfiles::
        SlowProfileQuarantine
        .clear_all!

      cleanup_records
    end

    test "selects legacy and stale profiles but not valid current profile" do
      current_version =
        ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION

      strict_v1 = profiled_cluster(profile_version: "strict_v1")
      strict_v2 = profiled_cluster(profile_version: "strict_v2")
      strict_v3 = profiled_cluster(profile_version: "strict_v3_core")
      without_version = profiled_cluster(profile_version: nil)
      valid_current =
        profiled_cluster(
          profile_version: current_version
        )
      dirty_current =
        profiled_cluster(
          profile_version: current_version,
          dirty: true
        )
      mismatch_current =
        profiled_cluster(
          profile_version: current_version,
          profile_composition_version: 1,
          cluster_composition_version: 2
        )

      selected_ids = next_cluster_ids

      assert_includes selected_ids, strict_v1.id
      assert_includes selected_ids, strict_v2.id
      assert_includes selected_ids, strict_v3.id
      assert_includes selected_ids, without_version.id
      refute_includes selected_ids, valid_current.id
      assert_includes selected_ids, dirty_current.id
      assert_includes selected_ids, mismatch_current.id
    end

    test "prioritizes missing profiles before legacy migrations" do
      missing =
        cluster_with_addresses(
          address_count: 2
        )

      legacy =
        profiled_cluster(
          profile_version: "strict_v2"
        )

      selected_ids =
        next_cluster_ids(limit: 2)

      assert_equal(
        [missing.id, legacy.id],
        selected_ids
      )
    end

    test "prioritizes urgent stale profiles before missing profiles" do
      missing =
        cluster_with_addresses(
          address_count: 2
        )

      urgent =
        profiled_cluster(
          profile_version:
            ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,
          dirty: true
        )

      selected_ids =
        next_cluster_ids(limit: 2)

      assert_equal(
        [urgent.id, missing.id],
        selected_ids
      )
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

    test "continues selected clusters after first profile timeout" do
      height = @height

      builder =
        ActorProfiles::StrictBatchBuilder.new(
          limit: 5,
          max_runtime_seconds: 120
        )

      builder.define_singleton_method(
        :current_cluster_tip
      ) { height }

      builder.define_singleton_method(
        :current_layer1_tip
      ) { height }

      builder.define_singleton_method(
        :next_cluster_ids
      ) { [11, 12, 13, 14, 15] }

      builder.define_singleton_method(
        :missing_profiles_count
      ) { 0 }

      builder.define_singleton_method(
        :stale_profiles_count
      ) { 0 }

      calls = []

      build =
        lambda do |cluster_id:|
          calls << cluster_id

          if cluster_id == 11
            raise ActorProfiles::
              DeferredSnapshotError.new(
                "ActorProfile stage timed out",
                cluster_id: cluster_id,
                reason: "profile_timeout",
                details: {
                  stage: "transaction_counts",
                  runtime_ms: 1_000
                }
              )
          end

          {
            ok: true,
            runtime_ms: 10,
            stage_timings_ms: {
              "transaction_counts" => 1
            }
          }
        end

      ActorProfiles::CertificationEpoch.stub(
        :active?,
        true
      ) do
        ActorProfile.stub(:count, 0) do
          ActorProfiles::
            StrictBuildFromCluster.stub(
              :call,
              build
            ) do
              result = builder.call

              assert_equal(
                [11, 12, 13, 14, 15],
                calls
              )

              assert_equal 5, result[:selected]
              assert_equal 5, result[:processed]
              assert_equal 4, result[:built]
              assert_equal 1, result[:deferred]
              assert_equal 0, result[:failed]
              assert_equal 1, result[:slow_quarantined]
              assert_nil result[:stopped_reason]
            end
        end
      end
    end

    test "excludes slow quarantined cluster from next selection" do
      quarantined =
        cluster_with_addresses(
          address_count: 2
        )

      available =
        cluster_with_addresses(
          address_count: 2
        )

      ActorProfiles::
        SlowProfileQuarantine
        .quarantine!(
          cluster_id: quarantined.id,
          reason: "profile_timeout",
          runtime_ms: 1_000,
          now: Time.current
        )

      selected_ids =
        next_cluster_ids(
          limit: 2
        )

      refute_includes selected_ids, quarantined.id
      assert_includes selected_ids, available.id
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

        certification_epoch_height:
          @height - 1,

        certification_scope:
          ActorProfile::
            CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,

        certified_at:
          Time.current,

        last_computed_height: cluster.last_seen_height,
        cluster_composition_version: profile_composition_version,
        traits: traits,
        metadata: metadata
      )

      cluster
    end

    def cluster_with_addresses(
      address_count:,
      composition_version: 1,
      last_seen_height: @height - 1
    )
      cluster =
        Cluster.create!(
          address_count: address_count,
          first_seen_height:
            last_seen_height - 10,

          last_seen_height:
            last_seen_height,
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
      ActorProfileCertificationEpoch.delete_all
      ActorProfile.delete_all
      Address.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
