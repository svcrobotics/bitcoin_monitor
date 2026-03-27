# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClusterAggregator do
  describe ".call" do
    let!(:cluster) { Cluster.create! }

    let!(:address_1) do
      Address.create!(
        address: "bc1qagg111111111111111111111111111111111111",
        cluster: cluster,
        first_seen_height: 100,
        last_seen_height: 200,
        tx_count: 3,
        total_sent_sats: 150_000_000
      )
    end

    let!(:address_2) do
      Address.create!(
        address: "bc1qagg222222222222222222222222222222222222",
        cluster: cluster,
        first_seen_height: 120,
        last_seen_height: 250,
        tx_count: 7,
        total_sent_sats: 350_000_000
      )
    end

    it "builds or updates the cluster profile from cluster addresses" do
      profile = described_class.call(cluster)

      expect(profile).to be_persisted
      expect(profile.cluster_id).to eq(cluster.id)
      expect(profile.cluster_size).to eq(2)
      expect(profile.tx_count).to eq(10)
      expect(profile.total_sent_sats).to eq(500_000_000)
      expect(profile.first_seen_height).to eq(100)
      expect(profile.last_seen_height).to eq(250)
    end

    it "keeps profile total_sent_sats aligned with addresses sum" do
      described_class.call(cluster)

      cluster.reload
      profile = cluster.cluster_profile

      expect(profile.total_sent_sats).to eq(cluster.addresses.sum(:total_sent_sats))
    end

    it "updates an existing profile instead of creating a duplicate" do
      existing = ClusterProfile.create!(
        cluster: cluster,
        cluster_size: 999,
        tx_count: 999,
        total_sent_sats: 999,
        first_seen_height: 999,
        last_seen_height: 999,
        classification: "unknown",
        score: 1,
        traits: []
      )

      expect do
        described_class.call(cluster)
      end.not_to change(ClusterProfile, :count)

      existing.reload
      expect(existing.cluster_size).to eq(2)
      expect(existing.tx_count).to eq(10)
      expect(existing.total_sent_sats).to eq(500_000_000)
      expect(existing.first_seen_height).to eq(100)
      expect(existing.last_seen_height).to eq(250)
    end

    it "runs classification and scoring" do
      profile = described_class.call(cluster)

      expect(profile.classification).to be_present
      expect(profile.score).to be_present
      expect(profile.score).to be_between(0, 100)
    end

    it "returns nil when cluster has no addresses" do
      empty_cluster = Cluster.create!

      expect(described_class.call(empty_cluster)).to be_nil
      expect(empty_cluster.cluster_profile).to be_nil
    end
  end
end