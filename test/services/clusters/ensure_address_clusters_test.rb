# frozen_string_literal: true

require "minitest/mock"
require "test_helper"

module Clusters
  class EnsureAddressClustersTest < ActiveSupport::TestCase
    test "assigns one existing cluster per address in batches" do
      addresses =
        3.times.map do |index|
          Address.create!(
            address: "batch-ensure-address-#{SecureRandom.hex(8)}-#{index}"
          )
        end

      result = nil

      ActorProfiles::DirtyMarker.stub(:mark, true) do
        result =
          Clusters::EnsureAddressClusters.call(
            addresses: addresses.map(&:address)
          )
      end

      addresses.each(&:reload)
      cluster_ids = addresses.map(&:cluster_id)

      assert_equal true, result[:ok]
      assert_equal 3, result[:updated]
      assert_equal 3, result[:clusters]
      assert_equal 3, cluster_ids.compact.uniq.size
      assert_equal 3, Cluster.where(id: cluster_ids).count
    end

    test "is idempotent when addresses already have clusters" do
      cluster = Cluster.create!
      address =
        Address.create!(
          address: "batch-idempotent-#{SecureRandom.hex(8)}",
          cluster: cluster
        )

      result = nil

      ActorProfiles::DirtyMarker.stub(:mark, true) do
        result =
          Clusters::EnsureAddressClusters.call(
            addresses: [address.address]
          )
      end

      assert_equal true, result[:ok]
      assert_equal 0, result[:updated]
      assert_equal 0, result[:clusters]
      assert_equal cluster.id, address.reload.cluster_id
    end
  end
end
