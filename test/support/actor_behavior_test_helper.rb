# frozen_string_literal: true

require "bigdecimal"
require "securerandom"

module ActorBehaviorTestHelper
  def create_certified_actor_profile(
    balance_btc: "1500.0",
    total_received_btc: "1500.0",
    total_sent_btc: "0.0",
    net_btc: nil,
    tx_count: 250,
    inflow_count: 250,
    outflow_count: 0,
    address_count: 1,
    dirty: false,
    last_computed_height: 100,
    profile_version: ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,
    profile_composition_version: 1,
    cluster_composition_version: 1,
    updated_at: Time.current
  )
    cluster =
      Cluster.create!(
        address_count: address_count,
        first_seen_height: 90,
        last_seen_height: 100,
        composition_version: cluster_composition_version
      )

    address_count.times do |index|
      Address.create!(
        address: "behavior-batch-#{index}-#{SecureRandom.hex(8)}",
        cluster: cluster
      )
    end

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
      whale_score: behavior_score_for_balance(balance_btc),
      exchange_score: 20,
      service_score: 20,
      dirty: dirty,
      last_computed_height: last_computed_height,
      cluster_composition_version: profile_composition_version,
      traits: {
        "profile_version" => profile_version,
        "address_count" => address_count,
        "first_seen_height" => 90,
        "last_seen_height" => 100
      },
      metadata: {
        "strict" => true
      },
      created_at: updated_at,
      updated_at: updated_at
    )
  end

  def create_current_behavior_snapshot(profile)
    ActorBehaviors::StrictBuildFromProfile
      .call(actor_profile: profile)
      .fetch(:snapshot)
  end

  def behavior_score_for_balance(balance_btc)
    balance =
      BigDecimal(balance_btc.to_s).abs

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
  end
end
