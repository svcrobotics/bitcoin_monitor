# frozen_string_literal: true

require "test_helper"

module Actors
  class RebuildExchangeCoreAddressesTest <
    ActiveSupport::TestCase

    test "preview does not modify exchange core addresses" do
      cluster =
        create_exchange_cluster(
          address_count: 2
        )

      result =
        RebuildExchangeCoreAddresses.call(
          dry_run: true
        )

      assert_equal true, result[:ok]
      assert_equal "preview", result[:status]
      assert_equal 2, result[:addresses_count]
      assert_equal 0, result[:inserted_count]

      assert_includes(
        result[:cluster_ids],
        cluster.id
      )

      assert_equal(
        0,
        ExchangeCoreAddress.count
      )
    end

    test "rebuild materializes strict exchange addresses" do
      first_cluster =
        create_exchange_cluster(
          address_count: 2
        )

      second_cluster =
        create_exchange_cluster(
          address_count: 1
        )

      legacy_cluster =
        Cluster.create!(
          address_count: 1,
          composition_version: 1,
          last_seen_height: 100
        )

      ExchangeCoreAddress.create!(
        address:
          "legacy-#{SecureRandom.hex(12)}",

        cluster_id:
          legacy_cluster.id,

        source:
          "legacy"
      )

      result =
        RebuildExchangeCoreAddresses.call(
          dry_run: false
        )

      assert_equal true, result[:ok]
      assert_equal "rebuilt", result[:status]
      assert_equal 1, result[:previous_count]
      assert_equal 3, result[:inserted_count]
      assert_equal 3, ExchangeCoreAddress.count

      assert_equal(
        [
          first_cluster.id,
          second_cluster.id
        ].sort,

        ExchangeCoreAddress
          .distinct
          .pluck(:cluster_id)
          .sort
      )

      assert_equal(
        [
          ActorLabels::StrictWriter::SOURCE
        ],

        ExchangeCoreAddress
          .distinct
          .pluck(:source)
      )
    end

    test "refuses an empty strict perimeter and preserves existing rows" do
      legacy_cluster =
        Cluster.create!(
          address_count: 1,
          composition_version: 1,
          last_seen_height: 100
        )

      existing =
        ExchangeCoreAddress.create!(
          address:
            "preserved-#{SecureRandom.hex(12)}",

          cluster_id:
            legacy_cluster.id,

          source:
            "legacy"
        )

      result =
        RebuildExchangeCoreAddresses.call(
          dry_run: false
        )

      assert_equal false, result[:ok]
      assert_equal "refused", result[:status]

      assert_equal(
        "no_strict_exchange_like_clusters",
        result[:reason]
      )

      assert_equal(
        1,
        result[:preserved_existing_rows]
      )

      assert_equal(
        existing.id,
        ExchangeCoreAddress.first.id
      )
    end

    private

    def create_exchange_cluster(
      address_count:
    )
      cluster =
        Cluster.create!(
          address_count:
            address_count,

          first_seen_height:
            90,

          last_seen_height:
            100,

          composition_version:
            1
        )

      address_count.times do |index|
        Address.create!(
          address:
            "exchange-core-" \
            "#{index}-" \
            "#{SecureRandom.hex(12)}",

          cluster:
            cluster
        )
      end

      profile =
        ActorProfile.create!(
          cluster:
            cluster,

          balance_btc:
            "0",

          total_received_btc:
            "0",

          total_sent_btc:
            "0",

          net_btc:
            "0",

          tx_count:
            10_000,

          inflow_count:
            0,

          outflow_count:
            0,

          whale_score:
            5,

          exchange_score:
            70,

          service_score:
            0,

          etf_score:
            0,

          dirty:
            false,

          last_computed_height:
            100,

          cluster_composition_version:
            1,

          traits: {
            "profile_version" =>
              ActorProfiles::
                StrictBuildFromCluster::
                PROFILE_VERSION,

            "address_count" =>
              address_count
          },

          metadata: {
            "strict" => true
          }
        )

      ActorLabel.create!(
        cluster:
          cluster,

        actor_profile:
          profile,

        label:
          "exchange_like",

        confidence:
          70,

        source:
          ActorLabels::StrictWriter::SOURCE,

        metadata: {
          "strict" => true,
          "behavior_based" => true,
          "behavior_version" =>
            "strict_v2",

          "rule_version" =>
            "actor_labels_behavior_strict_v2_1"
        },

        first_seen_at:
          Time.current,

        last_seen_at:
          Time.current
      )

      cluster
    end
  end
end
