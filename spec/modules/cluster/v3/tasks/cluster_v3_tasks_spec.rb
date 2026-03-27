# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "cluster:v3 tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  before do
    Rake::Task["cluster:v3:build_metrics"].reenable
    Rake::Task["cluster:v3:detect_signals"].reenable
  end

  let!(:cluster) { Cluster.create! }

  let!(:profile) do
    ClusterProfile.create!(
      cluster: cluster,
      cluster_size: 2,
      tx_count: 100,
      total_sent_sats: 50_000_000_000,
      first_seen_height: 1_000,
      last_seen_height: 2_000,
      classification: "retail",
      score: 40,
      traits: []
    )
  end

  describe "cluster:v3:build_metrics" do
    it "builds metrics for clusters" do
      expect {
        Rake::Task["cluster:v3:build_metrics"].invoke
      }.to change(ClusterMetric, :count).by_at_least(1)
    end
  end

  describe "cluster:v3:detect_signals" do
    before do
      ClusterMetric.create!(
        cluster: cluster,
        snapshot_date: Date.current,
        tx_count_24h: 1_000,
        tx_count_7d: 3_500,
        sent_sats_24h: 60_000_000_000,
        sent_sats_7d: 140_000_000_000,
        activity_score: 90
      )
    end

    it "detects signals for clusters" do
      expect {
        Rake::Task["cluster:v3:detect_signals"].invoke
      }.to change(ClusterSignal, :count).by_at_least(1)
    end
  end
end