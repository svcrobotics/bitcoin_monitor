# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class StrictWriterTest < ActiveSupport::TestCase
    test "dry run reports labels without writing" do
      snapshot =
        create_snapshot(
          exchange: true,
          service: true
        )

      result =
        ActorLabels::StrictWriter.call(
          snapshot: snapshot,
          dry_run: true
        )

      assert_equal true, result[:eligible]

      assert_equal(
        %w[exchange_like service_like],
        result[:expected_labels]
      )

      assert_empty result[:written_labels]

      assert_equal(
        0,
        ActorLabel.where(
          source:
            ActorLabels::StrictRuleSet::SOURCE
        ).count
      )
    end

    test "writes all expected behavior labels" do
      snapshot =
        create_snapshot(
          whale: true,
          exchange: true,
          service: true,
          etf_candidate: true
        )

      result =
        ActorLabels::StrictWriter.call(
          snapshot: snapshot,
          dry_run: false
        )

      assert_equal true, result[:ok]

      assert_equal(
        4,
        result[:written_labels].size
      )

      labels =
        ActorLabel
          .where(
            cluster_id:
              snapshot.cluster_id,

            source:
              ActorLabels::StrictRuleSet::SOURCE
          )
          .order(:label)

      assert_equal(
        %w[
          etf_candidate
          exchange_like
          service_like
          whale_like
        ],
        labels.pluck(:label)
      )

      labels.each do |label|
        assert_equal true,
                     label.metadata["behavior_based"]

        assert_equal snapshot.id,
                     label.metadata[
                       "actor_behavior_snapshot_id"
                     ]
      end
    end

    test "is idempotent" do
      snapshot =
        create_snapshot(
          exchange: true
        )

      2.times do
        ActorLabels::StrictWriter.call(
          snapshot: snapshot,
          dry_run: false
        )
      end

      assert_equal(
        1,
        ActorLabel.where(
          cluster_id: snapshot.cluster_id,
          source:
            ActorLabels::StrictRuleSet::SOURCE
        ).count
      )
    end

    test "removes obsolete labels from its source only" do
      snapshot =
        create_snapshot

      ActorLabel.create!(
        cluster_id:
          snapshot.cluster_id,

        actor_profile_id:
          snapshot.actor_profile_id,

        label:
          "exchange_like",

        confidence:
          80,

        source:
          ActorLabels::StrictRuleSet::SOURCE
      )

      legacy =
        ActorLabel.create!(
          cluster_id:
            snapshot.cluster_id,

          actor_profile_id:
            snapshot.actor_profile_id,

          label:
            "whale_like",

          confidence:
            90,

          source:
            "legacy_test_source"
        )

      result =
        ActorLabels::StrictWriter.call(
          snapshot: snapshot,
          dry_run: false
        )

      assert_equal(
        ["exchange_like"],
        result[:deleted_labels]
      )

      refute ActorLabel.exists?(
        cluster_id:
          snapshot.cluster_id,

        source:
          ActorLabels::StrictRuleSet::SOURCE
      )

      assert ActorLabel.exists?(legacy.id)
    end

    test "does not delete labels for ineligible behavior" do
      snapshot =
        create_snapshot(
          status: "deferred"
        )

      existing =
        ActorLabel.create!(
          cluster_id:
            snapshot.cluster_id,

          actor_profile_id:
            snapshot.actor_profile_id,

          label:
            "exchange_like",

          confidence:
            80,

          source:
            ActorLabels::StrictRuleSet::SOURCE
        )

      result =
        ActorLabels::StrictWriter.call(
          snapshot: snapshot,
          dry_run: false
        )

      assert_equal false, result[:eligible]

      assert_equal(
        :behavior_not_certified,
        result[:reason]
      )

      assert ActorLabel.exists?(existing.id)
    end

    private

    def create_snapshot(
      status: "certified",
      whale: false,
      exchange: false,
      service: false,
      etf_candidate: false
    )
      cluster =
        Cluster.create!(
          address_count: 1,
          composition_version: 1,
          last_seen_height: 100
        )

      profile =
        ActorProfile.create!(
          cluster: cluster,
          balance_btc: "0",
          total_received_btc: "0",
          total_sent_btc: "0",
          net_btc: "0",
          tx_count: 1,
          inflow_count: 0,
          outflow_count: 0,
          whale_score: 5,
          exchange_score: 0,
          service_score: 0,
          etf_score: 0,
          dirty: false,
          last_computed_height: 100,
          cluster_composition_version: 1,
          traits: {
            "profile_version" =>
              "strict_v4_core_facts",

            "address_count" => 1
          },
          metadata: {
            "strict" => true
          }
        )

      profile_fingerprint =
        SecureRandom.hex(32)

      certified_at =
        Time.current

      ActorBehaviorSnapshot.create!(
        cluster: cluster,
        actor_profile: profile,

        profile_version:
          "strict_v4_core_facts",

        profile_height:
          100,

        cluster_composition_version:
          1,

        profile_fingerprint:
          profile_fingerprint,

        source_hash:
          profile_fingerprint,

        certification_scope:
          "strict",

        certified_at:
          certified_at,

        behavior_version:
          "strict_v2",

        status:
          status,

        signals: {
          "holder_size" => "regular",
          "large_holder" => false,
          "very_large_holder" => false,

          "whale_like_candidate_inputs" =>
            whale,

          "whale_candidate_inputs" =>
            false,

          "exchange_like_candidate_inputs" =>
            exchange,

          "service_like_candidate_inputs" =>
            service,

          "etf_candidate_inputs" =>
            etf_candidate,

          "retail_like_candidate_inputs" =>
            false
        },

        scores: {
          "whale_score" =>
            whale ? 90 : 5,

          "exchange_score" =>
            exchange ? 80 : 0,

          "service_score" =>
            service ? 75 : 0,

          "etf_score" =>
            etf_candidate ? 70 : 0
        },

        evidence: {
          "behavior_version" => "strict_v2"
        },

        computed_at:
          certified_at
      )
    end
  end
end
