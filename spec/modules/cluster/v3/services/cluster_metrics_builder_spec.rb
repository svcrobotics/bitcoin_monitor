# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClusterMetricsBuilder do
  describe ".call" do
    let(:snapshot_date) { Date.new(2026, 3, 23) }

    it "returns nil when cluster has no profile" do
      cluster = Cluster.create!

      result = described_class.call(cluster, snapshot_date: snapshot_date)

      expect(result).to be_nil
      expect(ClusterMetric.count).to eq(0)
    end

    it "creates a metric for a young cluster using full profile values when age <= 144 blocks" do
      cluster = Cluster.create!
      ClusterProfile.create!(
        cluster: cluster,
        cluster_size: 3,
        tx_count: 20,
        total_sent_sats: 1_500_000_000,
        first_seen_height: 1_000,
        last_seen_height: 1_100, # age = 100
        classification: "retail",
        score: 25,
        traits: []
      )

      metric = described_class.call(cluster, snapshot_date: snapshot_date)

      expect(metric).to be_persisted
      expect(metric.snapshot_date).to eq(snapshot_date)
      expect(metric.tx_count_24h).to eq(20)
      expect(metric.tx_count_7d).to eq(20)
      expect(metric.sent_sats_24h).to eq(1_500_000_000)
      expect(metric.sent_sats_7d).to eq(1_500_000_000)
      expect(metric.activity_score).to be_between(0, 100)
    end

    it "projects 24h and 7d metrics for an older cluster" do
      cluster = Cluster.create!
      ClusterProfile.create!(
        cluster: cluster,
        cluster_size: 10,
        tx_count: 2_000,
        total_sent_sats: 50_000_000_000,
        first_seen_height: 1_000,
        last_seen_height: 3_000, # age = 2000
        classification: "retail",
        score: 40,
        traits: []
      )

      metric = described_class.call(cluster, snapshot_date: snapshot_date)

      expected_tx_24h = [(2_000.0 / 2_000) * 144, 2_000].min.round
      expected_tx_7d  = [(2_000.0 / 2_000) * 1008, 2_000].min.round

      expected_sats_24h = [(50_000_000_000.0 / 2_000) * 144, 50_000_000_000].min.round
      expected_sats_7d  = [(50_000_000_000.0 / 2_000) * 1008, 50_000_000_000].min.round

      expect(metric.tx_count_24h).to eq(expected_tx_24h)
      expect(metric.tx_count_7d).to eq(expected_tx_7d)
      expect(metric.sent_sats_24h).to eq(expected_sats_24h)
      expect(metric.sent_sats_7d).to eq(expected_sats_7d)
    end

    it "is idempotent for the same cluster and snapshot_date" do
      cluster = Cluster.create!
      ClusterProfile.create!(
        cluster: cluster,
        cluster_size: 5,
        tx_count: 100,
        total_sent_sats: 10_000_000_000,
        first_seen_height: 1_000,
        last_seen_height: 2_000,
        classification: "retail",
        score: 30,
        traits: []
      )

      first = described_class.call(cluster, snapshot_date: snapshot_date)
      second = described_class.call(cluster, snapshot_date: snapshot_date)

      expect(ClusterMetric.where(cluster: cluster, snapshot_date: snapshot_date).count).to eq(1)
      expect(second.id).to eq(first.id)
    end

    it "computes sent_btc helper methods correctly" do
      cluster = Cluster.create!
      ClusterProfile.create!(
        cluster: cluster,
        cluster_size: 2,
        tx_count: 10,
        total_sent_sats: 1_234_567_890,
        first_seen_height: 1,
        last_seen_height: 10,
        classification: "retail",
        score: 10,
        traits: []
      )

      metric = described_class.call(cluster, snapshot_date: snapshot_date)

      expect(metric.sent_btc_24h).to be_a(Numeric)
      expect(metric.sent_btc_7d).to be_a(Numeric)
    end
  end
end