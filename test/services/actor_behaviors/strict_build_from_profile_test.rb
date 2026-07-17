# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class StrictBuildFromProfileTest < ActiveSupport::TestCase
    test "creates snapshot from certified profile" do
      profile =
        create_certified_profile(
          balance_btc: "1500.0",
          address_count: 10,
          tx_count: 250
        )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      assert_equal true, result[:ok]
      assert_equal "certified", result[:status]
      assert_equal true, result[:created]

      snapshot =
        result.fetch(:snapshot)

      assert_equal profile.cluster_id, snapshot.cluster_id
      assert_equal profile.id, snapshot.actor_profile_id
      assert_equal "certified", snapshot.status
      assert_equal "strict_v2", snapshot.behavior_version
      assert_equal snapshot.profile_fingerprint, snapshot.source_hash
      assert_equal "strict", snapshot.certification_scope
      assert snapshot.certified_at.present?
      assert_equal 85, snapshot.scores["whale_score"]
      assert_equal true, snapshot.signals["large_holder"]
      assert_equal false, snapshot.signals["very_large_holder"]
      assert_equal "large", snapshot.signals["holder_size"]
    end

    test "is idempotent on two identical executions" do
      profile =
        create_certified_profile

      first =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      first_certified_at =
        first.fetch(:snapshot).certified_at

      second =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile.reload
        )

      assert_equal "certified", first[:status]
      assert_equal "certified", second[:status]
      assert_equal first[:snapshot].id, second[:snapshot].id
      assert_equal false, second[:created]
      assert_equal false, second[:updated]
      assert_equal true, second[:unchanged]
      assert_equal first_certified_at, second.fetch(:snapshot).certified_at
      assert_equal 1, ActorBehaviorSnapshot.where(cluster_id: profile.cluster_id).count
      assert_equal(
        first[:source_profile_fingerprint],
        second[:source_profile_fingerprint]
      )
    end

    test "updates snapshot when fingerprint changes" do
      profile =
        create_certified_profile(
          balance_btc: "1500.0"
        )

      first =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      profile.update!(
        balance_btc: "12000.0"
      )

      second =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile.reload
        )

      assert_equal first[:snapshot].id, second[:snapshot].id
      assert_equal true, second[:updated]
      refute_equal(
        first[:source_profile_fingerprint],
        second[:source_profile_fingerprint]
      )
      assert_equal 100, second[:snapshot].reload.scores["whale_score"]
      assert_equal true, second[:snapshot].signals["very_large_holder"]
    end

    test "refuses dirty profile" do
      profile =
        create_certified_profile(
          dirty: true
        )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      assert_equal "deferred", result[:status]
      assert_equal :profile_dirty, result[:reason]
      assert_nil result[:snapshot]
      assert_equal 0, ActorBehaviorSnapshot.count
    end

    test "refuses composition mismatch" do
      profile =
        create_certified_profile(
          profile_composition_version: 1,
          cluster_composition_version: 2
        )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      assert_equal "deferred", result[:status]
      assert_equal :cluster_composition_mismatch, result[:reason]
      assert_equal 0, ActorBehaviorSnapshot.count
    end

    test "refuses legacy actor profile version" do
      profile =
        create_certified_profile(
          profile_version: "strict_v2"
        )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      assert_equal "deferred", result[:status]
      assert_equal :profile_version_mismatch, result[:reason]
      assert_equal 0, ActorBehaviorSnapshot.count
    end

    test "preserves profile checkpoint fields exactly" do
      profile =
        create_certified_profile(
          last_computed_height: 955_999,
          profile_composition_version: 7,
          cluster_composition_version: 7
        )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      snapshot =
        result.fetch(:snapshot)

      assert_equal 955_999, snapshot.profile_height
      assert_equal(
        ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,
        snapshot.profile_version
      )
      assert_equal 7, snapshot.cluster_composition_version
    end

    test "does not replace valid snapshot on deferred result" do
      profile =
        create_certified_profile

      first =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      fingerprint =
        first[:snapshot].profile_fingerprint

      profile.update!(
        dirty: true,
        balance_btc: "12000.0"
      )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile.reload
        )

      assert_equal "deferred", result[:status]
      assert_equal :profile_dirty, result[:reason]
      assert_equal fingerprint, first[:snapshot].reload.profile_fingerprint
      assert_equal 85, first[:snapshot].scores["whale_score"]
    end

    test "does not replace valid snapshot on failed calculation" do
      profile =
        create_certified_profile

      first =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      fingerprint =
        first[:snapshot].profile_fingerprint

      with_failed_behavior_calculation do
        result =
          ActorBehaviors::StrictBuildFromProfile.call(
            actor_profile: profile.reload
          )

        assert_equal "failed", result[:status]
        assert_equal :calculation_failed, result[:reason]
      end

      assert_equal fingerprint, first[:snapshot].reload.profile_fingerprint
    end

    test "does not modify actor profile or actor labels" do
      profile =
        create_certified_profile

      before_attributes =
        profile.reload.attributes

      assert_no_difference -> { ActorLabel.count } do
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )
      end

      assert_equal before_attributes, profile.reload.attributes
    end

    test "new scores match current actor profile scores on strict fixture" do
      profile =
        create_certified_profile(
          balance_btc: "12000.0",
          address_count: 1_000,
          tx_count: 10_000
        )

      result =
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )

      snapshot =
        result.fetch(:snapshot)

      assert_equal profile.whale_score, snapshot.scores["whale_score"]
      assert_equal profile.exchange_score, snapshot.scores["exchange_score"]
      assert_equal profile.service_score, snapshot.scores["service_score"]
    end

    test "evidence explains applied thresholds" do
      profile =
        create_certified_profile(
          balance_btc: "1500.0"
        )

      snapshot =
        ActorBehaviors::StrictBuildFromProfile
          .call(actor_profile: profile)
          .fetch(:snapshot)

      evidence =
        snapshot.evidence

      assert_equal "strict_v2", evidence["behavior_version"]
      assert_equal(
        "1000",
        evidence.dig(
          "thresholds",
          "whale_score",
          "large_balance_btc"
        )
      )
      assert_includes(
        evidence.fetch("reasons"),
        "balance_maps_to_holder_size"
      )
      assert evidence.dig("facts", "balance_btc").present?
    end

    test "does not query tx_outputs or historical projections" do
      profile =
        create_certified_profile

      queries = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql = payload[:sql].to_s.downcase
          queries << sql if sql.include?("tx_outputs")
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorBehaviors::StrictBuildFromProfile.call(
          actor_profile: profile
        )
      end

      assert_empty queries
    end

    test "does not depend on actor labels implementation" do
      source =
        Rails.root.join(
          "app/services/actor_behaviors/strict_build_from_profile.rb"
        ).read

      refute_match(/ActorLabels::/, source)
    end

    private

    def create_certified_profile(
      balance_btc: "1500.0",
      total_received_btc: "1500.0",
      total_sent_btc: "0.0",
      net_btc: nil,
      tx_count: 250,
      inflow_count: 250,
      outflow_count: 0,
      address_count: 10,
      dirty: false,
      last_computed_height: 100,
      profile_version: ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,
      profile_composition_version: 1,
      cluster_composition_version: 1
    )
      epoch =
        ActorProfileCertificationEpoch.find_or_create_by!(
          profile_version:
            ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION
        ) do |record|
          record.start_height = 90
          record.activated_at = Time.current
          record.source =
            ActorProfileCertificationEpoch::SOURCE_CLUSTER_STRICT_CHECKPOINT
          record.metadata = {}
        end

      cluster =
        Cluster.create!(
          address_count: address_count,
          first_seen_height: 90,
          last_seen_height: 100,
          composition_version: cluster_composition_version
        )

      address_count.times do |index|
        Address.create!(
          address: "behavior-profile-#{index}-#{SecureRandom.hex(8)}",
          cluster: cluster
        )
      end

      scores =
        legacy_scores(
          balance_btc: balance_btc,
          address_count: address_count,
          tx_count: tx_count
        )

      ActorProfile.create!(
        cluster: cluster,
        balance_btc: balance_btc,
        total_received_btc: total_received_btc,
        total_sent_btc: total_sent_btc,
        net_btc: net_btc || balance_btc,
        tx_count: tx_count,
        inflow_count: inflow_count,
        outflow_count: outflow_count,
        first_seen_at: Time.utc(2026, 1, 1, 0, 0, 0),
        last_seen_at: Time.utc(2026, 1, 2, 0, 0, 0),
        whale_score: scores.fetch(:whale_score),
        exchange_score: scores.fetch(:exchange_score),
        service_score: scores.fetch(:service_score),
        dirty: dirty,
        last_computed_height: last_computed_height,
        cluster_composition_version: profile_composition_version,
        certification_epoch_height: epoch.start_height,
        certification_scope:
          ActorProfile::CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,
        certified_at: Time.current,
        traits: {
          "profile_version" => profile_version,
          "address_count" => address_count,
          "first_seen_height" => 90,
          "last_seen_height" => 100
        },
        metadata: {
          "strict" => true
        }
      )
    end

    def legacy_scores(balance_btc:, address_count:, tx_count:)
      balance =
        BigDecimal(balance_btc.to_s).abs

      whale_score =
        if balance >= 10_000
          100
        elsif balance >= 1_000
          85
        elsif balance >= 100
          65
        elsif balance >= 10
          35
        else
          5
        end

      exchange_score = [
        score_by_threshold(
          address_count,
          [
            [50_000, 100],
            [10_000, 90],
            [1_000, 70],
            [100, 40],
            [10, 15]
          ]
        ),
        score_by_threshold(
          tx_count,
          [
            [500_000, 100],
            [100_000, 90],
            [10_000, 70],
            [1_000, 45],
            [100, 20]
          ]
        )
      ].max

      service_score = [
        score_by_threshold(
          address_count,
          [
            [10_000, 85],
            [1_000, 70],
            [100, 45],
            [10, 20]
          ]
        ),
        score_by_threshold(
          tx_count,
          [
            [100_000, 85],
            [10_000, 70],
            [1_000, 45],
            [100, 20]
          ]
        )
      ].max

      {
        whale_score: whale_score,
        exchange_score: exchange_score,
        service_score: service_score
      }
    end

    def score_by_threshold(value, thresholds)
      numeric =
        BigDecimal(value.to_s)

      thresholds.each do |threshold, score|
        return score if numeric >=
                        BigDecimal(threshold.to_s)
      end

      0
    end

    def with_failed_behavior_calculation
      klass =
        ActorBehaviors::StrictBuildFromProfile

      klass.class_eval do
        alias_method(
          :compute_behavior_without_test_failure,
          :compute_behavior
        )

        define_method(:compute_behavior) do |_profile|
          raise "boom"
        end
      end

      yield
    ensure
      klass.class_eval do
        remove_method :compute_behavior
        alias_method(
          :compute_behavior,
          :compute_behavior_without_test_failure
        )
        remove_method :compute_behavior_without_test_failure
      end
    end
  end
end
