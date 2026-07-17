# frozen_string_literal: true

require "test_helper"

module Clusters
  class AddressWriterTest < ActiveSupport::TestCase
    test "lets ClusterMerger create one cluster for a new multi-input group" do
      address_values =
        4.times.map do |index|
          "writer-group-#{SecureRandom.hex(8)}-#{index}"
        end

      grouped_inputs =
        address_values.index_with do |address|
          {
            address: address,
            total_inputs: 1,
            total_value_sats: 1_000
          }
        end

      before_clusters = Cluster.count

      records =
        Clusters::AddressWriter.call(
          grouped_inputs: grouped_inputs,
          height: 954_321
        )

      assert_equal [nil], records.map(&:cluster_id).uniq

      result =
        Clusters::ClusterMerger.call(
          address_records: records
        )

      assigned_cluster_ids =
        Address
          .where(address: address_values)
          .distinct
          .pluck(:cluster_id)

      assert_equal 1, result.created
      assert_equal 0, result.merged
      assert_equal 1, Cluster.count - before_clusters
      assert_equal [result.cluster.id], assigned_cluster_ids
    end
  end
end
