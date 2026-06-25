# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class StrictRuleSetV2Test < ActiveSupport::TestCase
    test "defers historical labels for strict core profiles" do
      cluster =
        Cluster.create!(
          address_count: 1,
          last_seen_height: 100,
          composition_version: 1
        )

      Address.create!(
        address: "labels-core-#{SecureRandom.hex(8)}",
        cluster: cluster
      )

      profile =
        ActorProfile.create!(
          cluster: cluster,
          balance_btc: "1500.0",
          total_received_btc: nil,
          total_sent_btc: "10.0",
          net_btc: "1500.0",
          tx_count: 10_000,
          inflow_count: nil,
          outflow_count: 10_000,
          whale_score: 90,
          exchange_score: 10,
          service_score: 10,
          accumulation_score: 100,
          distribution_score: 100,
          etf_score: 100,
          dirty: false,
          last_computed_height: 100,
          cluster_composition_version: 1,
          traits: {
            "profile_version" => "strict_v3_core",
            "address_count" => 1
          },
          metadata: {
            "strict" => true,
            "historical_enrichment_status" => "missing"
          }
        )

      result =
        ActorLabels::StrictRuleSetV2.call(
          profile: profile,
          cluster_tip: 100
        )

      labels = result.fetch(:labels).map { |label| label.fetch(:label) }

      assert_equal true, result[:eligible]
      assert_includes labels, "whale_like"
      refute_includes labels, "accumulator_like"
      refute_includes labels, "distributor_like"
      refute_includes labels, "etf_candidate"
      refute_includes labels, "high_activity_like"
      assert_nil result.dig(:evidence, :metrics, :total_received_btc)
      assert_nil result.dig(:evidence, :metrics, :inflow_count)
      assert_nil result.dig(:evidence, :scores, :etf)
      assert_nil result.dig(:evidence, :scores, :accumulation)
      assert_nil result.dig(:evidence, :scores, :distribution)
    end

    test "rejects old strict profile versions" do
      cluster =
        Cluster.create!(
          address_count: 1,
          last_seen_height: 100,
          composition_version: 1
        )

      Address.create!(
        address: "labels-old-#{SecureRandom.hex(8)}",
        cluster: cluster
      )

      profile =
        ActorProfile.create!(
          cluster: cluster,
          balance_btc: "1500.0",
          total_received_btc: "1500.0",
          total_sent_btc: "10.0",
          net_btc: "1490.0",
          tx_count: 10,
          inflow_count: 10,
          outflow_count: 1,
          whale_score: 90,
          dirty: false,
          last_computed_height: 100,
          cluster_composition_version: 1,
          traits: {
            "profile_version" => "strict_v2"
          },
          metadata: {
            "strict" => true
          }
        )

      result =
        ActorLabels::StrictRuleSetV2.call(
          profile: profile,
          cluster_tip: 100
        )

      assert_equal false, result[:eligible]
      assert_equal :profile_not_strict_v3_core, result[:reason]
    end
  end
end
