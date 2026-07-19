# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class StrictBatchTest < ActiveSupport::TestCase
    test "dry run scans current certified behaviors without writing" do
      create_behavior(
        address_count: 1_000,
        tx_count: 10_000
      )

      create_behavior(
        address_count: 1,
        tx_count: 1
      )

      result =
        ActorLabels::StrictBatch.call(
          limit: 10,
          dry_run: true
        )

      assert_equal true, result[:ok]
      assert_equal true, result[:dry_run]

      assert_equal(
        2,
        result.dig(:batch, :scanned)
      )

      assert_equal(
        2,
        result.dig(:batch, :eligible)
      )

      assert_equal(
        1,
        result.dig(
          :batch,
          :snapshots_with_labels
        )
      )

      assert_equal(
        2,
        result.dig(:batch, :expected_labels)
      )

      assert_equal(
        2,
        result.dig(:batch, :expected_upserts)
      )

      assert_equal(
        0,
        result.dig(:batch, :expected_deletions)
      )

      assert_equal(
        1,
        result.dig(
          :batch,
          :expected_by_label,
          "exchange_like"
        )
      )

      assert_equal(
        1,
        result.dig(
          :batch,
          :expected_by_label,
          "service_like"
        )
      )

      assert_equal(
        0,
        ActorLabel.where(
          source:
            ActorLabels::StrictRuleSet::SOURCE
        ).count
      )
    end

    test "write mode is idempotent" do
      create_behavior(
        address_count: 1_000,
        tx_count: 10_000
      )

      2.times do
        result =
          ActorLabels::StrictBatch.call(
            limit: 10,
            dry_run: false
          )

        assert_equal true, result[:ok]
        assert_equal 0,
                     result.dig(:batch, :failed)
      end

      assert_equal(
        2,
        ActorLabel.where(
          source:
            ActorLabels::StrictRuleSet::SOURCE
        ).count
      )
    end

    test "ignores stale behavior versions" do
      snapshot =
        create_behavior(
          address_count: 1_000,
          tx_count: 10_000
        )

      snapshot.update!(
        behavior_version: "strict_v1"
      )

      result =
        ActorLabels::StrictBatch.call(
          limit: 10,
          dry_run: true
        )

      assert_equal(
        0,
        result.dig(:batch, :scanned)
      )

      assert_equal(
        0,
        result.dig(:batch, :expected_labels)
      )
    end

    test "does not depend directly on actor profiles or legacy labels" do
      source =
        Rails.root.join(
          "app/services/actor_labels/strict_batch.rb"
        ).read

      refute_match(/ActorProfiles::/, source)
      refute_match(/StrictWriter\.call/, source)
    end

    test "completed cycle keeps the last id as incremental cursor" do
      snapshot =
        create_behavior(
          address_count: 1,
          tx_count: 1
        )

      result =
        ActorLabels::StrictBatch.call(
          limit: 10,
          after_id: 0,
          dry_run: true
        )

      assert_equal false,
                   result.dig(:cursor, :has_more)

      assert_equal snapshot.id,
                   result.dig(:cursor, :last_id)

      assert_equal snapshot.id,
                   result.dig(:cursor, :next_after_id)
    end

    private

    def create_behavior(
      address_count:,
      tx_count:
    )
      cluster =
        Cluster.create!(
          address_count: address_count,
          composition_version: 1,
          last_seen_height: 100
        )

      Address.create!(
        address:
          "labels-batch-#{SecureRandom.hex(8)}",

        cluster:
          cluster
      )

      epoch =
        ActorProfileCertificationEpoch.find_or_create_by!(
          profile_version:
            ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION
        ) do |record|
          record.start_height = 90
          record.activated_at = Time.current
          record.source =
            ActorProfileCertificationEpoch::
              SOURCE_CLUSTER_STRICT_CHECKPOINT
          record.metadata = {}
        end

      profile =
        ActorProfile.create!(
          cluster: cluster,
          balance_btc: "0",
          total_received_btc: "0",
          total_sent_btc: "0",
          net_btc: "0",
          tx_count: tx_count,
          inflow_count: 0,
          outflow_count: 0,
          whale_score: 5,
          exchange_score: 0,
          service_score: 0,
          etf_score: 0,
          dirty: false,
          last_computed_height: 100,
          cluster_composition_version: 1,
          certification_epoch_height:
            epoch.start_height,
          certification_scope:
            ActorProfile::
              CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,
          certified_at:
            Time.current,

          traits: {
            "profile_version" =>
              ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,

            "address_count" =>
              address_count,

            "first_seen_height" =>
              90,

            "last_seen_height" =>
              100
          },

          metadata: {
            "strict" => true
          }
        )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      assert_equal "certified",
                   result[:status]

      result.fetch(:snapshot)
    end
  end
end
