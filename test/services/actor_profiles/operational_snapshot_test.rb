# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class OperationalSnapshotTest <
    ActiveSupport::TestCase

    self.use_transactional_tests = false

    def setup
      cleanup_records
      clear_cache
    end

    def teardown
      clear_cache
      cleanup_records
    end

    test "reports inactive epoch without historical backlog" do
      snapshot =
        OperationalSnapshot.refresh!

      assert_equal(
        "inactive",
        snapshot[:status]
      )

      assert_equal(
        false,
        snapshot.dig(
          :certification,
          :epoch_active
        )
      )

      assert_equal(
        0,
        snapshot.dig(
          :progress,
          :pending_profiles
        )
      )

      assert_equal(
        0,
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        )
      )

      assert_equal(
        "inactive",
        snapshot.dig(
          :activity,
          :pipeline_state
        )
      )

      assert_equal(
        "certification_epoch_inactive",
        snapshot.dig(
          :activity,
          :wait_reason
        )
      )
    end

    test "refresh from batch counts only active epoch scope" do
      epoch =
        ActorProfileCertificationEpoch.create!(
          profile_version:
            StrictBuildFromCluster::
              PROFILE_VERSION,

          start_height:
            100,

          activated_at:
            Time.current,

          source:
            ActorProfileCertificationEpoch::
              SOURCE_CLUSTER_STRICT_CHECKPOINT,

          metadata: {}
        )

      create_cluster(
        last_seen_height: 99
      )

      create_cluster(
        last_seen_height: 100
      )

      create_cluster(
        last_seen_height: 101
      )

      snapshot =
        OperationalSnapshot.refresh_from_batch(
          status:
            "completed",

          actor_profiles_count:
            1,

          missing_profiles_count:
            1,

          stale_profiles_count:
            0,

          layer1_tip:
            101,

          cluster_tip:
            101,

          selected:
            1,

          built:
            1,

          deferred:
            0,

          failed:
            0,

          duration_ms:
            10,

          avg_runtime_ms:
            10,

          selection_ms:
            1,

          build_loop_ms:
            8,

          counts_ms:
            1,

          successful_runtime_ms:
            8,

          deferred_or_overhead_runtime_ms:
            0,

          unattributed_runtime_ms:
            0
        )

      assert_equal(
        true,
        snapshot.dig(
          :certification,
          :epoch_active
        )
      )

      assert_equal(
        epoch.start_height,
        snapshot.dig(
          :certification,
          :certification_epoch_height
        )
      )

      assert_equal(
        2,
        snapshot.dig(
          :progress,
          :active_clusters_since_epoch
        )
      )

      assert_equal(
        1,
        snapshot.dig(
          :progress,
          :historical_clusters_outside_epoch
        )
      )

      assert_equal(
        1,
        snapshot.dig(
          :progress,
          :certified_profiles_since_epoch
        )
      )

      assert_equal(
        1,
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        )
      )

      assert_equal(
        50.0,
        snapshot.dig(
          :progress,
          :completion_pct
        )
      )
    end

    test "read reports automation missing when cached wait reason says backlog empty but backlog is positive" do
      cached = {
        module:
          "actor_profiles_strict",
        source:
          "actor_profiles_operational_snapshot",
        available:
          true,
        generated_at:
          Time.current,
        status:
          "healthy",
        progress: {
          pending_profiles:
            81_127,
          pending_profiles_since_epoch:
            81_127
        },
        certification: {
          epoch_active:
            true,
          certification_epoch_height:
            957_815
        },
        activity: {
          pipeline_state:
            "idle_synced",
          wait_reason:
            "backlog_empty"
        },
        issues:
          []
      }

      Sidekiq.redis do |redis|
        redis.set(
          OperationalSnapshot::CACHE_KEY,
          ActiveSupport::JSON.encode(cached)
        )
      end

      snapshot = OperationalSnapshot.new

      snapshot.define_singleton_method(:runtime_snapshot) do
        {
          process_present: true,
          process_count: 1,
          busy_workers: 0,
          queue_size: 0,
          scheduled_jobs: 0,
          retries: 0,
          dead_jobs: 0,
          lock_ttl: -2,
          schedule_marker_ttl: -2
        }
      end

      snapshot.define_singleton_method(:address_spend_snapshot) do
        {
          available: true,
          sync: {
            caught_up_to_cluster: true
          }
        }
      end

      result =
        snapshot.read

      assert_equal(
        "automation_missing",
        result.dig(
          :activity,
          :pipeline_state
        )
      )

      assert_equal(
        "automation_missing",
        result.dig(
          :activity,
          :wait_reason
        )
      )

      assert_includes(
        result[:issues],
        "automation_missing"
      )
    end

    test "missing cache keeps inactive epoch explicit" do
      snapshot =
        operational_snapshot_with(
          address_spend: {
            available: true,
            sync: {
              caught_up_to_cluster: true
            }
          }
        ).read

      assert_equal(
        false,
        snapshot.dig(
          :certification,
          :epoch_active
        )
      )

      assert_equal(
        0,
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        )
      )

      assert_equal(
        "inactive",
        snapshot.dig(
          :activity,
          :pipeline_state
        )
      )

      assert_equal(
        "certification_epoch_inactive",
        snapshot.dig(
          :activity,
          :wait_reason
        )
      )
    end

    test "missing cache and active epoch wait for address spend while preserving positive backlog" do
      create_tips(height: 120)
      create_epoch(start_height: 100)
      create_cluster(last_seen_height: 120)

      snapshot =
        operational_snapshot_with(
          address_spend: {
            available: true,
            sync: {
              caught_up_to_cluster: false
            }
          }
        ).read

      assert_equal(
        true,
        snapshot.dig(
          :certification,
          :epoch_active
        )
      )

      assert_operator(
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        ),
        :>,
        0
      )

      assert_equal(
        "waiting_for_address_spend",
        snapshot.dig(
          :activity,
          :pipeline_state
        )
      )

      assert_equal(
        "address_spend_projection_not_ready",
        snapshot.dig(
          :activity,
          :wait_reason
        )
      )
    end

    test "missing cache and ready projection expose positive backlog to pipeline controller" do
      create_tips(height: 120)
      create_epoch(start_height: 100)
      create_cluster(last_seen_height: 120)

      snapshot =
        operational_snapshot_with(
          address_spend: {
            available: true,
            sync: {
              caught_up_to_cluster: true
            }
          }
        ).read

      assert_operator(
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        ),
        :>,
        0
      )

      assert_equal(
        "automation_missing",
        snapshot.dig(
          :activity,
          :pipeline_state
        )
      )

      actor_profile =
        with_stubbed(
          OperationalSnapshot,
          :read,
          snapshot
        ) do
          System::PipelineController.send(
            :actor_profile_snapshot,
            cluster_processed: 120
          )
        end

      assert_operator(
        actor_profile[:pending_work],
        :>,
        0
      )

      assert_equal true,
                   actor_profile[
                     :checkpoint_available
                   ]
    end

    test "missing cache and ready projection keep empty backlog empty" do
      create_tips(height: 120)
      create_epoch(start_height: 100)
      cluster =
        create_cluster(last_seen_height: 120)
      create_certified_profile(
        cluster,
        height: 120,
        epoch_height: 100
      )

      snapshot =
        operational_snapshot_with(
          address_spend: {
            available: true,
            sync: {
              caught_up_to_cluster: true
            }
          }
        ).read

      assert_equal(
        0,
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        )
      )

      assert_equal(
        "idle_synced",
        snapshot.dig(
          :activity,
          :pipeline_state
        )
      )
    end

    private

    def operational_snapshot_with(address_spend:)
      snapshot =
        OperationalSnapshot.new

      snapshot.define_singleton_method(:runtime_snapshot) do
        {
          process_present: true,
          process_count: 1,
          busy_workers: 0,
          queue_size: 0,
          scheduled_jobs: 0,
          retries: 0,
          dead_jobs: 0,
          lock_ttl: -2,
          schedule_marker_ttl: -2
        }
      end

      snapshot.define_singleton_method(:address_spend_snapshot) do
        address_spend
      end

      snapshot
    end

    def create_tips(height:)
      BlockBufferModel.create!(
        height: height,
        block_hash:
          unique_hash("layer1"),
        status: "processed",
        processed_at: Time.current
      )

      ClusterProcessedBlock.create!(
        height: height,
        block_hash:
          unique_hash("cluster"),
        status: "processed",
        processed_at: Time.current
      )
    end

    def create_epoch(start_height:)
      ActorProfileCertificationEpoch.create!(
        profile_version:
          StrictBuildFromCluster::
            PROFILE_VERSION,
        start_height: start_height,
        activated_at: Time.current,
        source:
          ActorProfileCertificationEpoch::
            SOURCE_CLUSTER_STRICT_CHECKPOINT,
        metadata: {}
      )
    end

    def create_cluster(last_seen_height:)
      Cluster.create!(
        address_count:
          2,

        first_seen_height:
          last_seen_height - 10,

        last_seen_height:
          last_seen_height,

        composition_version:
          1
      )
    end

    def create_certified_profile(
      cluster,
      height:,
      epoch_height:
    )
      ActorProfile.create!(
        cluster: cluster,
        balance_btc: "1.0",
        total_received_btc: "1.0",
        total_sent_btc: "0.0",
        net_btc: "1.0",
        tx_count: 1,
        inflow_count: 1,
        outflow_count: 0,
        dirty: false,
        last_computed_height: height,
        cluster_composition_version:
          cluster.composition_version,
        certification_epoch_height:
          epoch_height,
        certification_scope:
          ActorProfile::
            CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,
        certified_at: Time.current,
        traits: {
          "profile_version" =>
            StrictBuildFromCluster::
              PROFILE_VERSION
        },
        metadata: {
          "strict" => true
        }
      )
    end

    def unique_hash(prefix)
      Digest::SHA256.hexdigest(
        "#{prefix}-#{SecureRandom.hex(16)}"
      )
    end

    def with_stubbed(object, method_name, replacement)
      original =
        object.method(method_name)

      object.define_singleton_method(
        method_name
      ) do |*args, **kwargs, &block|
        if replacement.respond_to?(:call)
          replacement.call(
            *args,
            **kwargs,
            &block
          )
        else
          replacement
        end
      end

      yield
    ensure
      object.define_singleton_method(
        method_name,
        original
      )
    end

    def clear_cache
      Sidekiq.redis do |redis|
        redis.del(
          OperationalSnapshot::CACHE_KEY,
          OperationalSnapshot::RECENT_BATCHES_KEY
        )
      end
    end

    def cleanup_records
      ActorLabel.delete_all
      ActorProfile.delete_all
      Address.delete_all
      ActorProfileCertificationEpoch.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
