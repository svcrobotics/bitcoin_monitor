# frozen_string_literal: true

require "test_helper"

module Clusters
  class ClusterCompositionVersionTest < ActiveSupport::TestCase
    test "new strict cluster starts at the initial composition version" do
      records =
        2.times.map do |index|
          Address.create!(
            address:
              "composition-create-#{SecureRandom.hex(8)}-#{index}"
          )
        end

      result =
        Clusters::ClusterMerger.call(
          address_records: records
        )

      assert_equal 1, result.created
      assert_equal(
        Cluster::INITIAL_COMPOSITION_VERSION,
        result.cluster.reload.composition_version
      )
    end

    test "attaching an unclustered address advances composition version" do
      cluster =
        Cluster.create!(
          composition_version:
            Cluster::INITIAL_COMPOSITION_VERSION
        )

      existing =
        Address.create!(
          address: "composition-existing-#{SecureRandom.hex(8)}",
          cluster: cluster
        )

      unclustered =
        Address.create!(
          address: "composition-unclustered-#{SecureRandom.hex(8)}"
        )

      before_version =
        cluster.composition_version

      result =
        Clusters::ClusterMerger.call(
          address_records: [
            existing.reload,
            unclustered.reload
          ]
        )

      assert_equal 0, result.created
      assert_equal 0, result.merged
      assert_equal(
        before_version + 1,
        cluster.reload.composition_version
      )
      assert_equal cluster.id, unclustered.reload.cluster_id
    end

    test "merge advances canonical cluster beyond source revisions" do
      master =
        Cluster.create!(composition_version: 2)

      merged =
        Cluster.create!(composition_version: 5)

      master_address =
        Address.create!(
          address: "composition-master-#{SecureRandom.hex(8)}",
          cluster: master
        )

      merged_address =
        Address.create!(
          address: "composition-merged-#{SecureRandom.hex(8)}",
          cluster: merged
        )

      result =
        Clusters::ClusterMerger.call(
          address_records: [
            master_address.reload,
            merged_address.reload
          ]
        )

      assert_equal master.id, result.cluster.id
      assert_equal 1, result.merged
      assert_equal 6, master.reload.composition_version
      assert_equal master.id, merged_address.reload.cluster_id
      assert_not Cluster.exists?(merged.id)
    end

    test "recalculate stats does not advance composition version" do
      cluster =
        Cluster.create!(composition_version: 7)

      Address.create!(
        address: "composition-stats-#{SecureRandom.hex(8)}",
        cluster: cluster,
        total_received_sats: 12,
        total_sent_sats: 3
      )

      assert_no_changes -> { cluster.reload.composition_version } do
        cluster.recalculate_stats!
      end
    end

    test "failed merge rolls back composition and address changes" do
      master =
        Cluster.create!(composition_version: 2)

      merged =
        Cluster.create!(composition_version: 5)

      master_address =
        Address.create!(
          address: "composition-rollback-master-#{SecureRandom.hex(8)}",
          cluster: master
        )

      merged_address =
        Address.create!(
          address: "composition-rollback-merged-#{SecureRandom.hex(8)}",
          cluster: merged
        )

      merger =
        Clusters::ClusterMerger.new(
          address_records: [
            master_address.reload,
            merged_address.reload
          ]
        )

      def merger.cleanup_merged_clusters!(_cluster_ids)
        raise "forced rollback"
      end

      assert_raises(RuntimeError) do
        merger.call
      end

      assert_equal 2, master.reload.composition_version
      assert_equal 5, merged.reload.composition_version
      assert_equal master.id, master_address.reload.cluster_id
      assert_equal merged.id, merged_address.reload.cluster_id
      assert Cluster.exists?(merged.id)
    end
  end
end
