# frozen_string_literal: true

require "test_helper"

module Layer1
  class DashboardSnapshotTest < ActiveSupport::TestCase
    test "healthy status with one processing block returns a complete verdict" do
      dashboard = build_dashboard(
        snapshot: healthy_snapshot,
        proof: conformant_proof
      )

      assert_equal "healthy", dashboard[:status]
      assert_equal "Synchronisé et opérationnel", dashboard[:status_label]
      assert_includes dashboard[:status_summary], "retard normal de 1 bloc"
      assert_includes dashboard[:status_summary], "bloc 954 460 en cours de traitement"
      assert_includes dashboard[:status_summary], "buffers temps réel sont vides"
      assert_includes dashboard[:status_summary], "5/5 contrôles"
      refute_includes dashboard[:status_summary], "verdict complet"
    end

    test "active pipeline names the exact block being processed" do
      dashboard = build_dashboard(
        snapshot: healthy_snapshot,
        proof: conformant_proof
      )

      assert_equal "active", dashboard.dig(:pipeline, :state)
      assert_equal(
        "Bloc 954 460 en cours de traitement",
        dashboard.dig(:pipeline, :label)
      )
      assert_includes(
        dashboard.dig(:pipeline, :description),
        "Layer1 traite actuellement le bloc 954 460"
      )
      assert_includes(
        dashboard.dig(:pipeline, :description),
        "Le retard d’un bloc correspond au bloc en cours de certification"
      )
    end

    test "warning status names the exact reason under surveillance" do
      snapshot = healthy_snapshot.deep_merge(
        status: "warning",
        bitcoin_core_height: 954_463,
        processed_height: 954_460,
        lag: 3,
        buffers: {
          outputs: 0,
          spent: 7_206
        },
        strict: {
          worker: {
            present: true,
            busy: 0,
            pid: 12_345
          },
          processing_block: {
            height: 954_461,
            status: "processing",
            processing_started_at: Time.current - 2.minutes,
            last_heartbeat_at: Time.current - 15.seconds
          }
        }
      )

      dashboard = build_dashboard(
        snapshot: snapshot,
        proof: conformant_proof
      )

      assert_equal "warning", dashboard[:status]
      assert_includes dashboard[:status_summary], "bloc 954 461"
      assert_includes dashboard[:status_summary], "signal sous surveillance"
      assert_includes dashboard[:status_summary], "retard de 3 blocs"
      assert_includes dashboard[:status_summary], "5/5 contrôles"
      refute_includes dashboard[:status_summary], "au moins un indicateur"
    end

    test "processing block takes precedence over an idle Sidekiq snapshot" do
      snapshot = healthy_snapshot.deep_merge(
        strict: {
          worker: {
            present: true,
            busy: 0,
            pid: 12_345
          }
        }
      )

      dashboard = build_dashboard(
        snapshot: snapshot,
        proof: conformant_proof
      )

      assert_equal "En traitement", dashboard.dig(:automation, :worker_label)
    end

    test "performance compares latest block with ten previous blocks" do
      rows = [
        processed_row(height: 954_459, duration_ms: 900_000)
      ] + 10.times.map do |index|
        processed_row(height: 954_458 - index, duration_ms: 300_000)
      end

      dashboard = build_dashboard(
        snapshot: healthy_snapshot,
        rows: rows,
        proof: conformant_proof
      )

      performance = dashboard[:performance]

      assert_equal 900_000, performance[:last_duration_ms]
      assert_equal 300_000, performance[:average_duration_ms]
      assert_equal 10, performance[:average_blocks_count]
      assert_equal 200, performance[:deviation_pct]
      assert_equal "slower", performance[:state]
      assert_includes performance[:description], "bloc 954 459"
      assert_includes performance[:description], "10 blocs précédents"
    end

    test "performance distinguishes a moderate slowdown from a normal duration" do
      rows = [
        processed_row(height: 954_460, duration_ms: 393_000)
      ] + 10.times.map do |index|
        processed_row(height: 954_459 - index, duration_ms: 293_000)
      end

      dashboard = build_dashboard(
        snapshot: healthy_snapshot,
        rows: rows,
        proof: conformant_proof
      )

      performance = dashboard[:performance]

      assert_equal 34, performance[:deviation_pct]
      assert_equal "slightly_slower", performance[:state]
      assert_equal "Légèrement au-dessus de la moyenne", performance[:label]
    end

    test "historical projection is reported as synced independently from certification" do
      snapshot = healthy_snapshot.deep_merge(
        bitcoin_core_height: 954_532,
        processed_height: 954_532,
        lag: 0,
        activity: {
          pipeline_state: "idle_synced"
        },
        strict: {
          processing_block: nil
        },
        tx_outputs_async: {
          enabled: true,
          worker: {
            present: true,
            busy: 0,
            pid: 23_456
          },
          queue_size: 0,
          scheduled_jobs: 0,
          pending_count: 0,
          failed_count: 0,
          last_synced_height: 954_532,
          projection_lag_blocks: 0
        }
      )

      dashboard = build_dashboard(
        snapshot: snapshot,
        proof: conformant_proof
      )

      projection = dashboard[:historical_projection]

      assert_equal "healthy", dashboard[:status]
      assert_equal "synced", projection[:state]
      assert_equal "Synchronisée", projection[:label]
      assert_equal 954_532, projection[:certified_height]
      assert_equal 954_532, projection[:last_synced_height]
      assert_equal 0, projection[:projection_lag_blocks]
      assert projection[:worker_present]
    end

    test "historical projection can pause without degrading Layer1 certification" do
      snapshot = healthy_snapshot.deep_merge(
        bitcoin_core_height: 954_533,
        processed_height: 954_532,
        lag: 1,
        tx_outputs_async: {
          enabled: true,
          worker: {
            present: true,
            busy: 0,
            pid: 23_456
          },
          queue_size: 0,
          scheduled_jobs: 0,
          pending_count: 1,
          failed_count: 0,
          oldest_pending_height: 954_532,
          last_synced_height: 954_531,
          projection_lag_blocks: 1
        }
      )

      dashboard = build_dashboard(
        snapshot: snapshot,
        proof: conformant_proof
      )

      projection = dashboard[:historical_projection]

      assert_equal "healthy", dashboard[:status]
      assert_equal "deferred", projection[:state]
      assert_equal "En pause — priorité au temps réel", projection[:label]
      assert_includes projection[:description], "certification des blocs reste intacte"
    end

    private

    def build_dashboard(snapshot:, rows: [], proof: empty_proof)
      service = Layer1::DashboardSnapshot.new(snapshot: snapshot)
      service.define_singleton_method(:recent_processed_rows) { rows }
      service.define_singleton_method(:proof_snapshot) { proof }
      service.call
    end

    def healthy_snapshot
      now = Time.current

      {
        status: "healthy",
        bitcoin_core_height: 954_460,
        processed_height: 954_459,
        lag: 1,
        buffers: {
          outputs: 0,
          spent: 0
        },
        activity: {
          pipeline_state: "active"
        },
        strict: {
          worker: {
            present: true,
            busy: 1,
            pid: 12_345
          },
          scheduler: {
            registered: true,
            enabled: true,
            status: "enabled",
            cron: "*/1 * * * *"
          },
          scheduler_process: {
            present: true
          },
          queue_size: 0,
          scheduled_jobs: 0,
          processing_block: {
            height: 954_460,
            status: "processing",
            processing_started_at: now - 2.minutes,
            last_heartbeat_at: now - 10.seconds
          }
        }
      }
    end

    def processed_row(height:, duration_ms:)
      {
        height: height,
        duration_ms: duration_ms.to_f,
        processed_at: Time.current
      }
    end

    def conformant_proof
      {
        last_audit: nil,
        last_audits: [],
        total_checks: 5,
        passed_checks: 5,
        compliance: 100,
        conformant: true
      }
    end

    def empty_proof
      {
        last_audit: nil,
        last_audits: [],
        total_checks: 0,
        passed_checks: 0,
        compliance: nil,
        conformant: false
      }
    end
  end
end
