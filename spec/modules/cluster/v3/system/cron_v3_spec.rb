# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cluster V3 cron scripts" do
  let(:build_script) { Rails.root.join("bin/cron_cluster_v3_build_metrics.sh") }
  let(:signals_script) { Rails.root.join("bin/cron_cluster_v3_detect_signals.sh") }

  it "has build_metrics script" do
    expect(File.exist?(build_script)).to eq(true)
  end

  it "has detect_signals script" do
    expect(File.exist?(signals_script)).to eq(true)
  end

  it "scripts are executable" do
    expect(File.executable?(build_script)).to eq(true)
    expect(File.executable?(signals_script)).to eq(true)
  end

  it "build_metrics script contains rake task call" do
    content = File.read(build_script)
    expect(content).to include("cluster:v3:build_metrics")
  end

  it "detect_signals script contains rake task call" do
    content = File.read(signals_script)
    expect(content).to include("cluster:v3:detect_signals")
  end
end