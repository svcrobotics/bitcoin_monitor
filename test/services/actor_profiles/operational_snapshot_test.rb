# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ActorProfiles
  class OperationalSnapshotTest < ActiveSupport::TestCase
    def setup
      @now = Time.zone.parse("2026-07-16 12:00:00")
      @runtime = {
        available: true,
        queue_size: 0,
        queue_latency_seconds: 0.0,
        scheduled_jobs: 1,
        worker_count: 1,
        busy_workers: 0
      }
    end

    test "reports canonical certified missing stale and AddressSpend metrics" do
      certified_cluster = create_cluster(version: 2)
      stale_cluster = create_cluster(version: 3)
      create_cluster(version: 1)
      create_profile(certified_cluster, version: 2, certified_at: @now - 5.minutes)
      create_profile(stale_cluster, version: 2, certified_at: @now - 2.hours)
      create_checkpoints(height: 100)

      snapshot = snapshot()

      assert_equal 3, snapshot.dig(:profiles, :total_clusters)
      assert_equal 2, snapshot.dig(:profiles, :present)
      assert_equal 1, snapshot.dig(:profiles, :certified)
      assert_equal 1, snapshot.dig(:profiles, :missing)
      assert_equal 1, snapshot.dig(:profiles, :stale)
      assert_equal 33.33, snapshot.dig(:profiles, :coverage_pct)
      assert_equal 1, snapshot.dig(:profiles, :certified_last_10m)
      assert_equal 100, snapshot.dig(:address_spend, :tip)
      assert_equal 0, snapshot.dig(:address_spend, :lag)
      assert JSON.generate(snapshot)
    end

    test "detects admissible backlog without automation" do
      cluster = create_cluster(version: 1)
      create_checkpoints(height: 101)
      create_handoff(cluster, height: 101)
      runtime = @runtime.merge(scheduled_jobs: 0, worker_count: 0)

      result = snapshot(sidekiq_runtime: runtime)

      assert_equal 1, result.dig(:handoffs, :admissible)
      assert_equal true, result.dig(:automation, :automation_missing)
      assert_includes result[:issues], "automation_missing"
    end

    test "does not report automation missing when AddressSpend is behind" do
      cluster = create_cluster(version: 1)
      ClusterProcessedBlock.create!(height: 102, block_hash: "cluster-102", status: "processed", processed_at: @now)
      create_handoff(cluster, height: 102, block_hash: "cluster-102")

      result = snapshot(sidekiq_runtime: @runtime.merge(scheduled_jobs: 0, worker_count: 0))

      assert_equal 0, result.dig(:handoffs, :admissible)
      assert_equal false, result.dig(:automation, :automation_missing)
    end

    test "Sidekiq unavailable remains unavailable without false zeros" do
      result = snapshot(sidekiq_runtime: { available: false })

      assert_equal "unavailable", result[:status]
      assert_equal false, result.dig(:automation, :available)
      assert_nil result.dig(:automation, :queue_size)
      assert_nil result.dig(:automation, :worker_count)
      assert_equal false, result.dig(:automation, :automation_missing)
    end

    test "stale failed and processing handoffs remain distinct" do
      cluster = create_cluster(version: 1)
      create_checkpoints(height: 103)
      failed = create_handoff(cluster, height: 103)
      failed.update!(status: "processing", claimed_at: @now - 1.hour)
      failed.update!(status: "failed", last_error_class: "Failure")
      processing = create_handoff(cluster, height: 103, version: 2)
      processing.update!(status: "processing", claimed_at: @now - 1.hour)

      result = snapshot()

      assert_equal 1, result.dig(:handoffs, :failed)
      assert_equal 1, result.dig(:handoffs, :processing)
      assert_equal 1, result.dig(:handoffs, :stale)
    end

    test "pipeline refusal is observable without controlling the data truth" do
      result = snapshot(pipeline_decision: { allowed: false })

      assert_equal false, result.dig(:admission, :allowed)
      assert_includes result[:issues], "pipeline_controller_refused"
    end

    test "PipelineController derives ActorProfile work from admissible PostgreSQL handoffs" do
      source = {
        available: true,
        profiles: { latest_height: 100 },
        handoffs: { admissible: 2, processing: 0, failed: 0 },
        automation: { queue_size: 0, busy_workers: 0 }
      }

      ActorProfiles::OperationalSnapshot.stub(:read, source) do
        result = System::PipelineController.actor_profile_snapshot(cluster_processed: 100)
        assert_equal 2, result[:pending_work]
        assert_equal true, result[:checkpoint_available]
        assert_equal false, result[:caught_up_to_cluster]
      end
    end

    test "database failure is unavailable and metrics are nil" do
      service = StrictHealthSnapshot.new(now: @now, sidekiq_runtime: @runtime, pipeline_decision: nil)
      service.stub(:database_snapshot, -> { raise ActiveRecord::StatementInvalid, "unavailable" }) do
        result = service.call
        assert_equal "unavailable", result[:status]
        assert_equal false, result[:available]
        assert_nil result.dig(:profiles, :certified)
        assert_nil result.dig(:handoffs, :pending)
      end
    end

    test "snapshot SQL is read-only and never references Redis admission" do
      sql = capture_sql { @result = snapshot() }
      mutations = sql.grep(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i)
      source = File.read(Rails.root.join("app/services/actor_profiles/strict_health_snapshot.rb"))

      assert_empty mutations
      assert_no_match(/DirtyMarker|DirtyClusterQueue|StrictBatchJob/, source)
      assert JSON.generate(@result)
    end

    private

    def snapshot(**options)
      OperationalSnapshot.call(
        now: @now,
        sidekiq_runtime: @runtime,
        **options
      )
    end

    def create_cluster(version:)
      Cluster.create!(composition_version: version, first_seen_height: 1, last_seen_height: 100)
    end

    def create_profile(cluster, version:, certified_at:)
      ActorProfile.create!(
        cluster: cluster,
        cluster_composition_version: version,
        last_computed_height: 100,
        certification_epoch_height: 100,
        certification_scope: "strict",
        certified_at: certified_at,
        dirty: false,
        traits: { profile_version: StrictBuildFromCluster::PROFILE_VERSION },
        metadata: { strict: true, runtime_ms: 10 }
      )
    end

    def create_checkpoints(height:)
      hash = "cluster-#{height}"
      ClusterProcessedBlock.create!(height: height, block_hash: hash, status: "processed", processed_at: @now)
      AddressSpendProjectionBlock.create!(height: height, block_hash: hash, status: "completed", completed_at: @now)
    end

    def create_handoff(cluster, height:, block_hash: nil, version: 1)
      ClusterActorProfileHandoff.create!(
        cluster: cluster,
        cluster_height: height,
        block_hash: block_hash || "cluster-#{height}",
        composition_version: version
      )
    end

    def capture_sql
      statements = []
      subscriber = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql].to_s unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end
  end
end
