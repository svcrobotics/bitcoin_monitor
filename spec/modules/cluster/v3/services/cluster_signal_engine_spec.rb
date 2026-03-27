# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClusterSignalEngine do
  describe ".call" do
    let(:snapshot_date) { Date.new(2026, 3, 23) }
    let!(:cluster) { Cluster.create! }

    def create_metric!(attrs = {})
      ClusterMetric.create!(
        {
          cluster: cluster,
          snapshot_date: snapshot_date,
          tx_count_24h: 0,
          tx_count_7d: 0,
          sent_sats_24h: 0,
          sent_sats_7d: 0,
          activity_score: 0
        }.merge(attrs)
      )
    end

    it "returns an empty array when no metric exists for the snapshot" do
      result = described_class.call(cluster, snapshot_date: snapshot_date)

      expect(result).to eq([])
      expect(ClusterSignal.count).to eq(0)
    end

    it "creates no signals for low activity / low volume" do
      create_metric!(
        tx_count_24h: 10,
        tx_count_7d: 50,
        sent_sats_24h: 100_000_000,
        sent_sats_7d: 500_000_000,
        activity_score: 10
      )

      result = described_class.call(cluster, snapshot_date: snapshot_date)

      expect(result).to eq([])
      expect(ClusterSignal.where(cluster: cluster, snapshot_date: snapshot_date)).to be_empty
    end

    it "creates a sudden_activity signal when tx_24h is much higher than 7d average" do
      create_metric!(
        tx_count_24h: 1_000,
        tx_count_7d: 3_500,
        sent_sats_24h: 0,
        sent_sats_7d: 0,
        activity_score: 70
      )

      described_class.call(cluster, snapshot_date: snapshot_date)

      signal = ClusterSignal.find_by!(
        cluster: cluster,
        snapshot_date: snapshot_date,
        signal_type: "sudden_activity"
      )

      expect(signal.severity).to eq("medium")
      expect(signal.score).to be_between(60, 95)
      expect(signal.metadata["tx_24h"]).to eq(1_000)
      expect(signal.metadata["tx_7d"]).to eq(3_500)
      expect(signal.metadata["ratio_24h_vs_7d"]).to be_present
    end

    it "creates a volume_spike signal when 24h volume is much higher than 7d average" do
      create_metric!(
        tx_count_24h: 10,
        tx_count_7d: 500,
        sent_sats_24h: 60_000_000_000,  # 600 BTC
        sent_sats_7d: 140_000_000_000,  # 1400 BTC, avg 200 BTC/day, ratio 3.0
        activity_score: 80
      )

      described_class.call(cluster, snapshot_date: snapshot_date)

      signal = ClusterSignal.find_by!(
        cluster: cluster,
        snapshot_date: snapshot_date,
        signal_type: "volume_spike"
      )

      expect(signal.severity).to eq("high")
      expect(signal.score).to be_between(75, 95)
      expect(signal.metadata["btc_24h"]).to be_present
      expect(signal.metadata["avg_daily_7d_btc"]).to be_present
      expect(signal.metadata["ratio_24h_vs_7d"]).to eq(3.0)
    end

    it "creates a large_transfers signal when 24h volume is >= 500 BTC and tx_count_24h <= 50" do
      create_metric!(
        tx_count_24h: 4,
        tx_count_7d: 100,
        sent_sats_24h: 384_655_960_000, # 3846.5596 BTC
        sent_sats_7d: 600_000_000_000,
        activity_score: 90
      )

      described_class.call(cluster, snapshot_date: snapshot_date)

      signal = ClusterSignal.find_by!(
        cluster: cluster,
        snapshot_date: snapshot_date,
        signal_type: "large_transfers"
      )

      expect(signal.severity).to eq("high")
      expect(signal.score).to eq(90)
      expect(signal.metadata["tx_24h"]).to eq(4)
      expect(signal.metadata["btc_24h"]).to eq(3846.5596)
    end

    it "creates a cluster_activation signal when tx_24h is high and tx_7d stays limited" do
      create_metric!(
        tx_count_24h: 250,
        tx_count_7d: 180,
        sent_sats_24h: 1_000_000_000,
        sent_sats_7d: 5_000_000_000,
        activity_score: 60
      )

      described_class.call(cluster, snapshot_date: snapshot_date)

      signal = ClusterSignal.find_by!(
        cluster: cluster,
        snapshot_date: snapshot_date,
        signal_type: "cluster_activation"
      )

      expect(signal.severity).to eq("medium")
      expect(signal.score).to eq(80)
      expect(signal.metadata["tx_24h"]).to eq(250)
      expect(signal.metadata["tx_7d"]).to eq(180)
    end

    it "replaces existing signals for the same cluster and snapshot_date" do
      create_metric!(
        tx_count_24h: 1_000,
        tx_count_7d: 3_500,
        sent_sats_24h: 60_000_000_000,
        sent_sats_7d: 140_000_000_000,
        activity_score: 90
      )

      described_class.call(cluster, snapshot_date: snapshot_date)
      first_ids = ClusterSignal.where(cluster: cluster, snapshot_date: snapshot_date).pluck(:id)

      described_class.call(cluster, snapshot_date: snapshot_date)
      second_ids = ClusterSignal.where(cluster: cluster, snapshot_date: snapshot_date).pluck(:id)

      expect(ClusterSignal.where(cluster: cluster, snapshot_date: snapshot_date).count).to be >= 1
      expect(second_ids).not_to eq(first_ids)
    end

    it "does not create sudden_activity when guard rails fail" do
      create_metric!(
        tx_count_24h: 400,
        tx_count_7d: 200, # tx_24h >= tx_7d => blocked
        sent_sats_24h: 0,
        sent_sats_7d: 0,
        activity_score: 40
      )

      described_class.call(cluster, snapshot_date: snapshot_date)

      expect(
        ClusterSignal.find_by(cluster: cluster, snapshot_date: snapshot_date, signal_type: "sudden_activity")
      ).to be_nil
    end
  end
end