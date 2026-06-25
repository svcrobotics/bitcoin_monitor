# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class CertifiedScopeTest < ActiveSupport::TestCase
    test "certifies strict core profile without tx_outputs gate" do
      cluster =
        Cluster.create!(
          address_count: 1,
          last_seen_height: 100,
          composition_version: 7
        )

      Address.create!(
        address: "certified-core-#{SecureRandom.hex(8)}",
        cluster: cluster
      )

      profile =
        ActorProfile.create!(
          cluster: cluster,
          balance_btc: "1.0",
          total_received_btc: nil,
          total_sent_btc: "0.1",
          net_btc: "1.0",
          tx_count: 1,
          inflow_count: nil,
          outflow_count: 1,
          dirty: false,
          last_computed_height: 100,
          cluster_composition_version: 7,
          traits: {
            "profile_version" => "strict_v3_core"
          },
          metadata: {
            "strict" => true,
            "historical_enrichment_status" => "missing"
          }
        )

      assert_includes ActorProfiles::CertifiedScope.call, profile
    end

    test "global tip alone does not exclude current cluster profile" do
      cluster =
        Cluster.create!(
          address_count: 1,
          last_seen_height: 100,
          composition_version: 3
        )

      Address.create!(
        address: "certified-tip-#{SecureRandom.hex(8)}",
        cluster: cluster
      )

      ClusterProcessedBlock.create!(
        height: 101,
        block_hash: Digest::SHA256.hexdigest(SecureRandom.hex(16)),
        status: "processed",
        processed_at: Time.current
      )

      profile =
        ActorProfile.create!(
          cluster: cluster,
          balance_btc: "2.0",
          total_sent_btc: "0.0",
          net_btc: "2.0",
          tx_count: 0,
          outflow_count: 0,
          dirty: false,
          last_computed_height: 100,
          cluster_composition_version: 3,
          traits: {
            "profile_version" => "strict_v3_core"
          },
          metadata: {
            "strict" => true,
            "historical_enrichment_status" => "missing"
          }
        )

      assert_includes ActorProfiles::CertifiedScope.call, profile
    end
  end
end
