# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class StrictHealthSnapshotTest < ActiveSupport::TestCase
    setup do
      ClusterActorProfileHandoff.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
      @now = Time.current
    end

    test "reports certified lag and durable handoff health from PostgreSQL" do
      cluster = Cluster.create!
      BlockBufferModel.create!(height: 12, block_hash: "layer1-12", status: "processed")
      ClusterProcessedBlock.create!(
        height: 10,
        block_hash: "cluster-10",
        status: "processed",
        processed_at: @now - 30.seconds
      )
      create_handoff!(cluster: cluster, status: "pending", created_at: @now - 120.seconds)
      create_handoff!(cluster: cluster, status: "processing", claimed_at: @now - 20.minutes,
        composition_version: 2)
      create_handoff!(cluster: cluster, status: "failed", composition_version: 3)

      snapshot = StrictHealthSnapshot.call(now: @now)

      assert_equal true, snapshot[:database_available]
      assert_equal 12, snapshot[:layer1_tip]
      assert_equal 10, snapshot[:cluster_tip]
      assert_equal 2, snapshot[:cluster_lag]
      assert_equal 1, snapshot.dig(:handoffs, :pending)
      assert_equal 1, snapshot.dig(:handoffs, :processing)
      assert_equal 1, snapshot.dig(:handoffs, :failed)
      assert_equal 1, snapshot.dig(:handoffs, :stale_claims)
      assert_operator snapshot.dig(:handoffs, :oldest_pending_age_seconds), :>=, 120
      assert_equal "critical", snapshot[:status]
      assert JSON.generate(snapshot)
    end

    test "missing checkpoints remain unknown rather than false zero" do
      snapshot = StrictHealthSnapshot.call(now: @now)

      assert_equal "unknown", snapshot[:status]
      assert_nil snapshot[:layer1_tip]
      assert_nil snapshot[:cluster_tip]
      assert_nil snapshot[:cluster_lag]
      assert_nil snapshot.dig(:handoffs, :oldest_pending_age_seconds)
    end

    test "database errors are unavailable with nil metrics" do
      BlockBufferModel.stub(:where, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
        snapshot = StrictHealthSnapshot.call(now: @now)
        assert_equal "unavailable", snapshot[:status]
        assert_equal false, snapshot[:database_available]
        assert_nil snapshot[:cluster_lag]
        assert_nil snapshot.dig(:handoffs, :pending)
        assert_equal "ActiveRecord::ConnectionNotEstablished", snapshot[:error_class]
      end
    end

    test "performs only SELECT statements and ignores cluster_inputs legacy markers" do
      sql = capture_sql { @snapshot = StrictHealthSnapshot.call(now: @now) }
      source = File.read(Rails.root.join("app/services/clusters/strict_health_snapshot.rb"))

      assert_empty sql.grep(/\A\s*(?:INSERT|UPDATE|DELETE|TRUNCATE)/i)
      assert_no_match(/ClusterInput|cluster_inputs\.cluster_processed_at|Redis|Sidekiq/, source)
      assert JSON.generate(@snapshot)
    end

    private

    def create_handoff!(cluster:, status:, composition_version: 1, claimed_at: nil,
      created_at: @now)
      handoff = ClusterActorProfileHandoff.create!(
        cluster_height: 10,
        block_hash: "cluster-10",
        cluster: cluster,
        composition_version: composition_version
      )
      attributes = { status: status, created_at: created_at, updated_at: created_at }
      attributes[:claimed_at] = claimed_at if claimed_at
      attributes[:last_error_class] = "RuntimeError" if status == "failed"
      handoff.update_columns(attributes)
      handoff
    end

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        statements << payload[:sql].to_s unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end
  end
end
