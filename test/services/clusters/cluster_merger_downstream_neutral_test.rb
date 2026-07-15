# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class ClusterMergerDownstreamNeutralTest < ActiveSupport::TestCase
    FORBIDDEN_WRITE_TABLES = %w[
      actor_profiles
      actor_labels
      actor_behavior_heavy_snapshots
      cluster_activity_states
      cluster_inputs
    ].freeze

    test "merges deterministically, versions the target, and retains downstream state" do
      target = create_cluster!(composition_version: 2)
      source = create_cluster!(composition_version: 5)
      target_address = create_address!("merge-target", cluster: target)
      source_address = create_address!("merge-source", cluster: source)
      actor_profile = ActorProfile.create!(cluster: source)
      actor_label = ActorLabel.create!(
        cluster: source,
        actor_profile: actor_profile,
        label: "service_like",
        source: "cluster_profile"
      )
      activity = ClusterActivityState.create!(cluster: source)

      sql = capture_sql do
        @result = Clusters::ClusterMerger.call(
          address_records: [source_address, target_address]
        )
      end

      assert_equal target.id, @result.target_cluster_id
      assert_equal [source.id], @result.source_cluster_ids
      assert_equal 1, @result.merged
      assert_equal 6, target.reload.composition_version
      assert_equal 5, source.reload.composition_version
      assert_equal 6, @result.composition_versions.fetch(target.id)
      assert_equal 5, @result.composition_versions.fetch(source.id)
      assert_equal [target.id], Address.where(id: [target_address.id, source_address.id]).distinct.pluck(:cluster_id)
      assert_equal 2, target.reload.address_count
      assert_equal 0, source.reload.address_count
      assert ActorProfile.exists?(actor_profile.id)
      assert ActorLabel.exists?(actor_label.id)
      assert ClusterActivityState.exists?(activity.id)
      assert_forbidden_tables_untouched(sql)
    end

    test "a repeated merge is idempotent and does not increment composition again" do
      target = create_cluster!(composition_version: 3)
      source = create_cluster!(composition_version: 4)
      first_address = create_address!("idempotent-a", cluster: target)
      second_address = create_address!("idempotent-b", cluster: source)

      first = Clusters::ClusterMerger.call(address_records: [first_address, second_address])
      version = target.reload.composition_version
      second = Clusters::ClusterMerger.call(
        address_records: [first_address.reload, second_address.reload]
      )

      assert_equal 5, version
      assert_equal 1, first.merged
      assert_equal 0, second.merged
      assert_equal [], second.source_cluster_ids
      assert_equal version, target.reload.composition_version
      assert Cluster.exists?(source.id)
    end

    test "attaching an unclustered address increments once and then remains stable" do
      cluster = create_cluster!(composition_version: 7)
      existing = create_address!("attach-existing", cluster: cluster)
      newcomer = create_address!("attach-new", cluster: nil)

      first = Clusters::ClusterMerger.call(address_records: [newcomer, existing])
      second = Clusters::ClusterMerger.call(
        address_records: [existing.reload, newcomer.reload]
      )

      assert_equal cluster.id, newcomer.reload.cluster_id
      assert_equal 8, cluster.reload.composition_version
      assert_equal 0, first.merged
      assert_equal 0, second.merged
      assert_equal 8, second.composition_versions.fetch(cluster.id)
    end

    test "addresses already in one cluster do not change its composition version" do
      cluster = create_cluster!(composition_version: 9)
      first = create_address!("stable-a", cluster: cluster)
      second = create_address!("stable-b", cluster: cluster)

      result = Clusters::ClusterMerger.call(address_records: [second, first])

      assert_equal cluster.id, result.target_cluster_id
      assert_equal 9, cluster.reload.composition_version
      assert_equal 0, result.merged
    end

    test "an error during recalculation rolls back address and version changes" do
      target = create_cluster!(composition_version: 2)
      source = create_cluster!(composition_version: 4)
      target_address = create_address!("rollback-a", cluster: target)
      source_address = create_address!("rollback-b", cluster: source)
      merger = Clusters::ClusterMerger.new(
        address_records: [target_address, source_address]
      )

      merger.stub(:recalculate_cluster!, ->(_cluster_id) { raise "recalculation failed" }) do
        error = assert_raises(RuntimeError) { merger.call }
        assert_equal "recalculation failed", error.message
      end

      assert_equal target.id, target_address.reload.cluster_id
      assert_equal source.id, source_address.reload.cluster_id
      assert_equal 2, target.reload.composition_version
      assert_equal 4, source.reload.composition_version
      assert Cluster.exists?(source.id)
    end

    test "the service has no Layer1 projection or downstream cleanup dependency" do
      source = File.read(Rails.root.join("app/services/clusters/cluster_merger.rb"))

      refute_match(/ActorProfile|ActorLabel|ActorBehavior|ClusterActivityState/, source)
      refute_match(/ClusterInput|cluster_inputs/, source)
      refute_match(/tx_outputs|utxo_outputs/, source)
      refute_match(/CleanupEmptyClusters|delete_all|destroy/, source)
    end

    private

    def create_cluster!(composition_version:)
      Cluster.create!(composition_version: composition_version)
    end

    def create_address!(value, cluster:)
      Address.create!(address: "#{value}-#{SecureRandom.hex(6)}", cluster: cluster)
    end

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        statements << payload[:sql].to_s unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end

    def assert_forbidden_tables_untouched(statements)
      statements.each do |statement|
        normalized = statement.squish
        FORBIDDEN_WRITE_TABLES.each do |table|
          refute_match(
            /\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+\"?#{Regexp.escape(table)}\"?/i,
            normalized
          )
        end
        refute_match(/\b(?:tx_outputs|utxo_outputs)\b/i, normalized)
      end
    end
  end
end
