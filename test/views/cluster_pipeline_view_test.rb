# frozen_string_literal: true

require "test_helper"

class ClusterPipelineViewTest <
  ActionView::TestCase

  test "renders cluster inputs calculations outputs and consumers" do
    render(
      partial:
        "questions/answers/cluster_pipeline",

      locals: {
        dashboard: dashboard
      }
    )

    assert_includes rendered, "Cluster"
    assert_includes rendered, "Regroupement d’adresses certifié"

    assert_includes rendered, "Entrées"
    assert_includes rendered, "Faits reçus depuis Layer1"
    assert_includes rendered, "cluster_inputs"
    assert_includes rendered, "Checkpoint Layer1"
    assert_includes rendered, "Périmètre strict récent"

    assert_includes rendered, "Calculs"
    assert_includes rendered, "Scan multi-input"
    assert_includes rendered, "Nettoyage des clusters vides"
    assert_includes rendered, "Audit du bloc"
    assert_includes rendered, "Checkpoint certifié"
    assert_includes rendered, "2 430"
    assert_includes rendered, "201"
    assert_includes rendered, "4"

    assert_includes rendered, "Sorties"
    assert_includes rendered, "Graphe Cluster certifié"
    assert_includes rendered, "address_links"
    assert_includes rendered, "composition_version"
    assert_includes rendered, "Certification continue"
    assert_includes rendered, "Preuve stricte multi-input"
    assert_includes rendered, "Couverture complémentaire"

    assert_includes rendered, "Utilisé par"
    assert_includes rendered, "ActorProfile"
    assert_includes rendered, "Couverture Cluster"
    assert_includes rendered, "ActorBehavior et ActorLabels"
    assert_includes rendered, "Moteur de réponses Tansa"

    assert_includes rendered, "Voir les détails techniques"
    assert_includes rendered, "SYNCHRONISÉ ET CONFORME"
  end

  private

  def dashboard
    {
      status: "healthy",
      display_status: "healthy",
      status_label:
        "Synchronisé et conforme",

      status_summary:
        "Cluster a certifié le dernier bloc disponible depuis Layer1.",

      sync: {
        bitcoin_core_height: 956_772,
        layer1_tip: 956_767,
        layer1_status: "healthy",
        layer1_lag: 5,
        cluster_tip: 956_767,
        cluster_lag: 0
      },

      pipeline: {
        state: "idle_synced",
        label:
          "À jour — en attente du prochain bloc",

        description:
          "Cluster est synchronisé avec Layer1."
      },

      automation: {
        queue_name: "cluster_strict",
        process_present: true,
        active: false,
        worker_label: "Disponible",
        queue_size: 0,
        scheduled_jobs: 1,
        retry_jobs: 0,
        dead_jobs: 0,
        automation_ok: true
      },

      current_block: nil,

      performance: {
        last_duration_ms: 235_999,
        average_duration_ms: 210_000,
        average_sample_count: 10,
        throughput_per_hour: 17.1,
        eta_seconds: nil,

        last_block: {
          height: 956_767,
          duration_ms: 235_999,

          stage_timings: {
            cluster_scan: 230_929,
            cleanup_empty_clusters: 4_143,
            audit_block: 920
          },

          scan_result: {
            scanned_blocks: 1,
            scanned_txs: 615,
            multi_input_txs: 339,
            multi_address_candidates: 339,
            links_created: 2_430,
            clusters_created: 201,
            clusters_merged: 4,
            addresses_touched: 2_769
          },

          cleanup_result: {
            deleted_empty_clusters: 0,
            empty_clusters_count: 0
          },

          audit_result: {
            ok: true,
            processed_txs: 339,
            processed_inputs: 3_008,
            address_links_total: 5_435_261
          }
        },

        recent_blocks: [
          {
            height: 956_767,
            duration_ms: 235_999
          },
          {
            height: 956_766,
            duration_ms: 210_000
          }
        ]
      },

      proof: {
        applicable: true,
        pending: false,
        conformant: true,
        candidate_transactions: 339,
        processed_candidate_transactions: 339,
        passed_checks: 4,
        total_checks: 4,
        anomalies: 0,

        checks: {
          missing_addresses: 0,
          unclustered_addresses: 0,
          invalid_cluster_refs: 0,
          recent_empty_clusters: 0
        }
      },

      certification_history: {
        available: true,
        first_height: 955_000,
        last_height: 956_767,
        certified_blocks: 1_768,
        expected_blocks: 1_768,
        missing_blocks: 0,
        continuous: true
      },

      coverage: {
        applicable: true,
        pending: false,
        btc_coverage_pct: 99.95,
        addresses_nil_cluster: 12,
        outside_strict_inputs: 250
      },

      actor_profile: {
        count: 15_992,
        tip: 956_767,
        lag: 0,
        ready: true
      },

      counts: {
        cluster_inputs: 8_000_000,
        clusters: 1_043_202,
        addresses: 4_942_881,
        actor_profiles: 15_992
      },

      issues: []
    }
  end
end
