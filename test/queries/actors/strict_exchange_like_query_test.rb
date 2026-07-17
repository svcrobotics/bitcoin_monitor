# frozen_string_literal: true

require "test_helper"

module Actors
  class StrictExchangeLikeQueryTest <
    ActiveSupport::TestCase

    test "returns only strict behavior based exchange labels" do
      strict =
        create_label(
          label: "exchange_like",
          source:
            ActorLabels::StrictWriter::SOURCE,
          confidence: 92
        )

      create_label(
        label: "exchange_like",
        source: "actor_profile",
        confidence: 99
      )

      create_label(
        label: "service_like",
        source:
          ActorLabels::StrictWriter::SOURCE,
        confidence: 95
      )

      result =
        StrictExchangeLikeQuery.call

      assert_equal(
        [strict.id],
        result.pluck(:id)
      )
    end

    test "supports a minimum confidence" do
      low =
        create_label(
          label: "exchange_like",
          source:
            ActorLabels::StrictWriter::SOURCE,
          confidence: 70
        )

      high =
        create_label(
          label: "exchange_like",
          source:
            ActorLabels::StrictWriter::SOURCE,
          confidence: 94
        )

      result =
        StrictExchangeLikeQuery.call(
          min_confidence: 90
        )

      ids =
        result.pluck(:id)

      assert_not_includes ids, low.id
      assert_includes ids, high.id
    end

    test "supports distinct cluster projection" do
      first =
        create_label(
          label: "exchange_like",
          source:
            ActorLabels::StrictWriter::SOURCE,
          confidence: 70
        )

      second =
        create_label(
          label: "exchange_like",
          source:
            ActorLabels::StrictWriter::SOURCE,
          confidence: 90
        )

      cluster_ids =
        StrictExchangeLikeQuery
          .call
          .distinct
          .pluck(:cluster_id)

      assert_includes(
        cluster_ids,
        first.cluster_id
      )

      assert_includes(
        cluster_ids,
        second.cluster_id
      )
    end

    private

    def create_label(
      label:,
      source:,
      confidence:
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

          whale_score: 0,
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

      ActorLabel.create!(
        cluster: cluster,
        actor_profile: profile,

        label: label,
        confidence: confidence,
        source: source,

        metadata: {
          "strict" =>
            source ==
              ActorLabels::StrictWriter::SOURCE,

          "behavior_based" =>
            source ==
              ActorLabels::StrictWriter::SOURCE
        },

        first_seen_at: Time.current,
        last_seen_at: Time.current
      )
    end
  end
end
