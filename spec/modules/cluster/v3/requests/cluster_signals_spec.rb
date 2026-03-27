# spec/requests/cluster_signals_spec.rb
require "rails_helper"

RSpec.describe "ClusterSignals", type: :request do
  describe "GET /cluster_signals" do
    let!(:cluster_1) { Cluster.create!(address_count: 3) }
    let!(:cluster_2) { Cluster.create!(address_count: 10) }

    let!(:address_1) do
      Address.create!(
        address: "bc1qclustersignal11111111111111111111111111111",
        cluster: cluster_1,
        total_sent_sats: 100_000_000,
        tx_count: 2,
        first_seen_height: 100,
        last_seen_height: 200
      )
    end

    let!(:address_2) do
      Address.create!(
        address: "bc1qclustersignal22222222222222222222222222222",
        cluster: cluster_2,
        total_sent_sats: 500_000_000,
        tx_count: 5,
        first_seen_height: 110,
        last_seen_height: 210
      )
    end

    let!(:signal_low) do
      ClusterSignal.create!(
        cluster: cluster_1,
        snapshot_date: Date.current,
        signal_type: "volume_spike",
        severity: "medium",
        score: 70,
        metadata: {
          "btc_24h" => 10,
          "avg_daily_7d_btc" => 4,
          "ratio_24h_vs_7d" => 2.5
        }
      )
    end

    let!(:signal_high) do
      ClusterSignal.create!(
        cluster: cluster_2,
        snapshot_date: Date.current,
        signal_type: "large_transfers",
        severity: "high",
        score: 90,
        metadata: {
          "btc_24h" => 600,
          "tx_24h" => 4
        }
      )
    end

    it "renders successfully" do
      get cluster_signals_path

      expect(response).to have_http_status(:ok)
    end

    it "displays the page title" do
      get cluster_signals_path

      expect(response.body).to include("Signaux cluster récents")
    end

    it "displays translated signal titles" do
      get cluster_signals_path

      expect(response.body).to include("Volume élevé récent")
      expect(response.body).to include("Transferts massifs détectés")
    end

    it "displays linked addresses" do
      get cluster_signals_path

      expect(response.body).to include(address_1.address)
      expect(response.body).to include(address_2.address)
    end

    it "orders signals by descending score" do
      get cluster_signals_path

      high_pos = response.body.index("score 90")
      low_pos  = response.body.index("score 70")

      expect(high_pos).to be < low_pos
    end

    it "supports filtering by severity" do
      get cluster_signals_path(severity: "high")

      expect(response.body).to include("score 90")
      expect(response.body).not_to include("score 70")
    end

    it "supports filtering by signal type" do
      get cluster_signals_path(type: "large_transfers")

      expect(response.body).to include("Transferts massifs détectés")
      expect(response.body).not_to include("Volume élevé récent")
    end
  end

  describe "GET /cluster_signals/top" do
    let!(:cluster_1) { Cluster.create!(address_count: 5) }
    let!(:cluster_2) { Cluster.create!(address_count: 20) }

    let!(:address_1) do
      Address.create!(
        address: "bc1qtopcluster111111111111111111111111111111111",
        cluster: cluster_1,
        total_sent_sats: 100_000_000,
        tx_count: 2,
        first_seen_height: 100,
        last_seen_height: 200
      )
    end

    let!(:address_2) do
      Address.create!(
        address: "bc1qtopcluster222222222222222222222222222222222",
        cluster: cluster_2,
        total_sent_sats: 900_000_000,
        tx_count: 8,
        first_seen_height: 120,
        last_seen_height: 220
      )
    end

    let!(:profile_1) do
      ClusterProfile.create!(
        cluster: cluster_1,
        cluster_size: 5,
        tx_count: 2,
        total_sent_sats: 100_000_000,
        classification: "retail",
        score: 20,
        traits: []
      )
    end

    let!(:profile_2) do
      ClusterProfile.create!(
        cluster: cluster_2,
        cluster_size: 20,
        tx_count: 8,
        total_sent_sats: 900_000_000,
        classification: "whale",
        score: 80,
        traits: ["high_volume"]
      )
    end

    let!(:cluster_1_signal) do
      ClusterSignal.create!(
        cluster: cluster_1,
        snapshot_date: Date.current,
        signal_type: "sudden_activity",
        severity: "medium",
        score: 70,
        metadata: {
          "tx_24h" => 100,
          "tx_7d" => 300,
          "avg_daily_7d" => 42.86,
          "ratio_24h_vs_7d" => 2.33
        }
      )
    end

    let!(:cluster_2_signal_a) do
      ClusterSignal.create!(
        cluster: cluster_2,
        snapshot_date: Date.current,
        signal_type: "volume_spike",
        severity: "high",
        score: 95,
        metadata: {
          "btc_24h" => 1000,
          "avg_daily_7d_btc" => 200,
          "ratio_24h_vs_7d" => 5.0
        }
      )
    end

    let!(:cluster_2_signal_b) do
      ClusterSignal.create!(
        cluster: cluster_2,
        snapshot_date: Date.current,
        signal_type: "large_transfers",
        severity: "high",
        score: 90,
        metadata: {
          "btc_24h" => 1000,
          "tx_24h" => 3
        }
      )
    end

    it "renders successfully" do
      get top_cluster_signals_path

      expect(response).to have_http_status(:ok)
    end

    it "displays the page title" do
      get top_cluster_signals_path

      expect(response.body).to include("Top clusters du jour")
    end

    it "shows the highest ranked cluster first" do
      get top_cluster_signals_path

      cluster_2_pos = response.body.index("Cluster ##{cluster_2.id}")
      cluster_1_pos = response.body.index("Cluster ##{cluster_1.id}")

      expect(cluster_2_pos).to be < cluster_1_pos
    end

    it "displays the representative address" do
      get top_cluster_signals_path

      expect(response.body).to include(address_2.address)
    end

    it "displays translated signal type chips or items" do
      get top_cluster_signals_path

      expect(response.body).to include("Volume élevé récent")
      expect(response.body).to include("Transferts massifs détectés")
    end

    it "supports limiting the number of rows" do
      get top_cluster_signals_path(limit: 1)

      body = response.body
      expect(body).to include("Cluster ##{cluster_2.id}")
      expect(body).not_to include("Cluster ##{cluster_1.id}")
    end
  end
end