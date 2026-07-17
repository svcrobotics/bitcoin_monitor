# frozen_string_literal: true

require "test_helper"

module Clusters
  module Coverage
    class SingletonBuilderTest < ActiveSupport::TestCase
      VALID_P2PKH_ADDRESS =
        "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"

      VALID_P2SH_ADDRESS =
        "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"

      test "creates a singleton cluster for a valid unclustered address" do
        after_id =
          Address.maximum(:id).to_i

        address =
          Address.create!(
            address: VALID_P2PKH_ADDRESS,
            first_seen_height: 100,
            last_seen_height: 120,
            total_received_sats: 1_000,
            total_sent_sats: 250
          )

        result = nil

        assert_difference -> { Cluster.count }, 1 do
          result =
            Clusters::Coverage::SingletonBuilder.call(
              after_id: after_id
            )
        end

        address.reload
        cluster =
          Cluster.find(address.cluster_id)

        assert_equal true, result[:ok]
        assert_equal 1, result[:scanned]
        assert_equal 1, result[:valid_addresses]
        assert_equal 0, result[:invalid_addresses]
        assert_equal 1, result[:updated]
        assert_equal 1, result[:singleton_clusters_created]
        assert_equal 1, cluster.composition_version
        assert_equal 1, cluster.address_count
        assert_equal 1_000, cluster.total_received_sats
        assert_equal 250, cluster.total_sent_sats
        assert_equal 100, cluster.first_seen_height
        assert_equal 120, cluster.last_seen_height
      end

      test "is idempotent when replayed" do
        after_id =
          Address.maximum(:id).to_i

        address =
          Address.create!(
            address: VALID_P2PKH_ADDRESS
          )

        first_result =
          Clusters::Coverage::SingletonBuilder.call(
            after_id: after_id
          )

        first_cluster_id =
          address.reload.cluster_id

        assert_equal 1, first_result[:updated]
        assert first_cluster_id.present?

        assert_no_difference -> { Cluster.count } do
          second_result =
            Clusters::Coverage::SingletonBuilder.call(
              after_id: after_id
            )

          assert_equal true, second_result[:ok]
          assert_equal 0, second_result[:scanned]
          assert_equal 0, second_result[:updated]
          assert_equal 0, second_result[:singleton_clusters_created]
        end

        assert_equal first_cluster_id, address.reload.cluster_id
      end

      test "does not merge addresses or create address links" do
        after_id =
          Address.maximum(:id).to_i

        first_address =
          Address.create!(
            address: VALID_P2PKH_ADDRESS
          )

        second_address =
          Address.create!(
            address: VALID_P2SH_ADDRESS
          )

        assert_difference -> { Cluster.count }, 2 do
          assert_no_difference -> { AddressLink.count } do
            result =
              Clusters::Coverage::SingletonBuilder.call(
                after_id: after_id
              )

            assert_equal 2, result[:updated]
            assert_equal 2, result[:singleton_clusters_created]
          end
        end

        cluster_ids =
          [
            first_address.reload.cluster_id,
            second_address.reload.cluster_id
          ]

        assert_equal 2, cluster_ids.compact.uniq.size
      end

      test "ignores an address that already has a cluster" do
        after_id =
          Address.maximum(:id).to_i

        cluster =
          Cluster.create!(
            composition_version: 7
          )

        address =
          Address.create!(
            address: VALID_P2PKH_ADDRESS,
            cluster: cluster
          )

        updated_at =
          address.updated_at

        assert_no_difference -> { Cluster.count } do
          assert_no_difference -> { AddressLink.count } do
            result =
              Clusters::Coverage::SingletonBuilder.call(
                after_id: after_id
              )

            assert_equal true, result[:ok]
            assert_equal 0, result[:scanned]
            assert_equal 0, result[:updated]
            assert_equal 0, result[:singleton_clusters_created]
          end
        end

        address.reload

        assert_equal cluster.id, address.cluster_id
        assert_equal updated_at.to_i, address.updated_at.to_i
      end

      test "skips invalid bitcoin addresses without creating clusters" do
        after_id =
          Address.maximum(:id).to_i

        address =
          Address.create!(
            address: "not-a-bitcoin-address"
          )

        assert_no_difference -> { Cluster.count } do
          result =
            Clusters::Coverage::SingletonBuilder.call(
              after_id: after_id
            )

          assert_equal true, result[:ok]
          assert_equal 1, result[:scanned]
          assert_equal 0, result[:valid_addresses]
          assert_equal 1, result[:invalid_addresses]
          assert_equal 0, result[:updated]
          assert_equal 0, result[:singleton_clusters_created]
        end

        assert_nil address.reload.cluster_id
      end
    end
  end
end
