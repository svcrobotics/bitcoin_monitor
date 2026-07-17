# frozen_string_literal: true

require "test_helper"

module Clusters
  class DashboardSnapshotTest < ActiveSupport::TestCase
    test "shows healthy only when the strict multi-address audit is conformant" do
      dashboard = Clusters::DashboardSnapshot.call(snapshot: snapshot_with_audit)

      assert_equal "healthy", dashboard[:display_status]
      assert_equal "Synchronisé et conforme", dashboard[:status_label]
      assert_includes dashboard[:status_summary], "1 / 1 transactions multi-adresses"

      assert_equal 100, dashboard.dig(:proof, :compliance)
      assert_equal 4, dashboard.dig(:proof, :passed_checks)
      assert_equal 1, dashboard.dig(:proof, :candidate_transactions)
      assert_equal 1, dashboard.dig(:proof, :processed_candidate_transactions)
      assert_equal 2, dashboard.dig(:proof, :cluster_inputs)

      assert_equal 4, dashboard.dig(:coverage, :outside_strict_inputs)
      assert_equal 1, dashboard.dig(:coverage, :missing_distinct_addresses)
      assert_equal 1, dashboard.dig(:coverage, :unclustered_distinct_addresses)
    end

    test "shows warning when strict audit has an anomaly even at zero lag" do
      snapshot = snapshot_with_audit
      snapshot[:audit][:status] = "warning"
      snapshot[:audit][:integrity][:missing_addresses] = 1

      dashboard = Clusters::DashboardSnapshot.call(snapshot: snapshot)

      assert_equal "warning", dashboard[:display_status]
      assert_equal "Synchronisé sous surveillance", dashboard[:status_label]
      assert_equal 75, dashboard.dig(:proof, :compliance)
      assert_not dashboard.dig(:proof, :conformant)
    end


    test "builds the continuous certification history independently from the recent audit window" do
      (93_935..93_940).each do |height|
        ClusterProcessedBlock.create!(
          height: height,
          block_hash: format("%064x", height),
          status: "processed",
          processed_at: Time.current,
          scan_result: {},
          cleanup_result: {},
          audit_result: {}
        )
      end

      dashboard = Clusters::DashboardSnapshot.call(snapshot: snapshot_with_audit)
      history = dashboard[:certification_history]

      assert history[:available]
      assert history[:continuous]
      assert_equal 93_935, history[:first_height]
      assert_equal 93_940, history[:last_height]
      assert_equal 6, history[:certified_blocks]
      assert_equal 6, history[:expected_blocks]
      assert_equal 0, history[:missing_blocks]

      assert_equal 91, dashboard.dig(:proof, :first_height)
      assert_equal 100, dashboard.dig(:proof, :last_height)
      assert_equal 10, dashboard.dig(:proof, :heights).size
    end

    test "reports gaps in the certification history" do
      [94_000, 94_001, 94_003].each do |height|
        ClusterProcessedBlock.create!(
          height: height,
          block_hash: format("%064x", height),
          status: "processed",
          processed_at: Time.current,
          scan_result: {},
          cleanup_result: {},
          audit_result: {}
        )
      end

      history = Clusters::DashboardSnapshot.call(snapshot: snapshot_with_audit)[:certification_history]

      assert history[:available]
      assert_not history[:continuous]
      assert_equal 3, history[:certified_blocks]
      assert_equal 4, history[:expected_blocks]
      assert_equal 1, history[:missing_blocks]
    end

    test "builds performance from persisted ClusterProcessedBlock durations" do
      now = Time.current

      [
        [103, 90_000],
        [102, 120_000],
        [101, 180_000]
      ].each_with_index do |(height, duration_ms), index|
        ClusterProcessedBlock.create!(
          height: height,
          block_hash: "00dashboard#{height}",
          status: "processed",
          processing_started_at: now - index.minutes - duration_ms.fdiv(1_000),
          processed_at: now - index.minutes,
          duration_ms: duration_ms,
          stage_timings: { "cluster_scan" => duration_ms - 1_000 },
          scan_result: {},
          cleanup_result: {},
          audit_result: {}
        )
      end

      dashboard = Clusters::DashboardSnapshot.call(snapshot: snapshot_with_audit)
      performance = dashboard[:performance]

      assert_equal 90_000, performance[:last_duration_ms]
      assert_equal 150_000, performance[:average_duration_ms]
      assert_equal 2, performance[:average_sample_count]
      assert_equal 24.0, performance[:throughput_per_hour]
      assert_equal [103, 102, 101], performance[:recent_blocks].map { |row| row[:height] }
    end

    private

    def snapshot_with_audit
      {
        status: "healthy",
        sync: {
          layer1_tip: 100,
          cluster_tip: 100,
          scanner_lag: 0,
          bitcoin_core_height: 100,
          layer1_status: "healthy"
        },
        automation: {
          process: { present: true, busy: 0, pid: 123, concurrency: 1 },
          active_workers: 0,
          queue_size: 0,
          scheduled_jobs: 1,
          retry_jobs: 0,
          dead_jobs: 0,
          automation_ok: true
        },
        audit: {
          status: "healthy",
          heights: (91..100).to_a,
          counts: {
            cluster_inputs: 2,
            distinct_input_addresses: 2,
            candidate_transactions: 1,
            processed_candidate_transactions: 1,
            missing_processed_candidate_transactions: 0,
            touched_clusters: 1,
            total_cluster_inputs: 6,
            total_transactions: 5,
            total_distinct_addresses: 4
          },
          integrity: {
            missing_addresses: 0,
            unclustered_addresses: 0,
            invalid_cluster_refs: 0,
            recent_empty_clusters: 0
          },
          coverage: {
            total_inputs: 6,
            total_transactions: 5,
            distinct_addresses: 4,
            strict_inputs: 2,
            strict_transactions: 1,
            strict_distinct_addresses: 2,
            outside_strict_inputs: 4,
            missing_address_rows: 2,
            missing_distinct_addresses: 1,
            unclustered_rows: 2,
            unclustered_distinct_addresses: 1,
            invalid_cluster_refs: 0
          }
        },
        coverage: {
          window_blocks: 10,
          total_inputs: 6,
          total_btc: BigDecimal("1.0"),
          clustered_btc: BigDecimal("0.5"),
          nil_cluster_btc: BigDecimal("0.5"),
          btc_coverage_pct: 50.0,
          nil_cluster_inputs: 4,
          addresses_total: 4,
          addresses_nil_cluster: 1,
          total_transactions: 5,
          distinct_addresses: 4,
          strict_inputs: 2,
          strict_transactions: 1,
          strict_distinct_addresses: 2,
          outside_strict_inputs: 4,
          missing_address_rows: 2,
          missing_distinct_addresses: 1,
          unclustered_rows: 2,
          unclustered_distinct_addresses: 1,
          invalid_cluster_refs: 0
        },
        counts: {},
        activity: {},
        issues: []
      }
    end
  end
end
