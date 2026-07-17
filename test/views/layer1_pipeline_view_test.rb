# frozen_string_literal: true

require "test_helper"

class Layer1PipelineViewTest <
  ActionView::TestCase

  test "renders layer1 inputs calculations outputs consumers and asynchronous work" do
    render(
      partial:
        "questions/answers/layer1_pipeline",

      locals: {
        dashboard: dashboard
      }
    )

    assert_includes rendered, "Layer1"
    assert_includes rendered, "Infrastructure Bitcoin stricte"

    assert_includes rendered, "Entrées"
    assert_includes rendered, "Bitcoin Core RPC"
    assert_includes rendered, "block_buffers"
    assert_includes rendered, "Buffer outputs"
    assert_includes rendered, "Buffer spent"

    assert_includes rendered, "Calculs temps réel"
    assert_includes rendered, "Lecture Bitcoin Core"
    assert_includes rendered, "Traitement des transactions"
    assert_includes rendered, "Matérialisation PostgreSQL"
    assert_includes rendered, "Audits stricts"
    assert_includes rendered, "Publication des faits"

    assert_includes rendered, "Flux Outputs"
    assert_includes rendered, "Flux Spent"
    assert_includes rendered, "Coût moyen par ligne"
    assert_includes rendered, "Goulot principal"
    assert_includes rendered, "Analyse du bloc"
    assert_includes rendered, "Insertion dans utxo_outputs"
    assert_includes rendered, "Écriture dans cluster_inputs"
    assert_includes rendered, "Suppression des UTXO dépensés"
    assert_includes rendered, "Goulot principal"
    assert_includes rendered, "Analyse du bloc"

    assert_includes rendered, "Sorties certifiées"
    assert_includes rendered, "utxo_outputs"
    assert_includes rendered, "cluster_inputs"
    assert_includes rendered, "Audit outputs"
    assert_includes rendered, "Audit inputs"
    assert_includes rendered, "Audit état UTXO"
    assert_includes rendered, "9 355"
    assert_includes rendered, "7 844"

    assert_includes rendered, "Utilisé par"
    assert_includes rendered, "Cluster"
    assert_includes rendered, "ActorProfile"
    assert_includes rendered, "Modules analytiques"
    assert_includes rendered, "Moteur Tansa"

    assert_includes rendered, "Travaux asynchrones"
    assert_includes rendered, "Projection tx_outputs"
    assert_includes rendered, "Synchronisation tx_outputs.spent"
    assert_includes rendered, "Audit lourd indépendant"
    assert_includes rendered, "Cadence récente"
    assert_includes rendered, "Lancer un audit"

    assert_includes rendered, "Voir les détails techniques"
  end

  private

  def dashboard
    {
      source:
        "layer1_dashboard_snapshot",

      status:
        "warning",

      status_label:
        "Opérationnel sous surveillance",

      status_summary:
        "Layer1 reste opérationnel et résorbe actuellement son retard.",

      sync: {
        bitcoin_core_height: 956_792,
        processed_height: 956_774,
        lag: 18
      },

      buffers: {
        outputs: 0,
        spent: 0
      },

      pipeline: {
        state: "active",
        label: "Rattrapage en cours",
        description: "Layer1 traite des blocs."
      },

      automation: {
        worker_label: "En traitement",
        scheduler_status: "enabled",
        queue_size: 0
      },

      current_block: {
        height: 956_775,
        status: "processing"
      },

      performance: {
        last_duration_ms: 100_174,
        average_duration_ms: 108_000,

        last_block: {
          height: 956_774,
          duration_ms: 100_174,
          strict_outputs_count: 9_355,
          cluster_inputs_count: 7_844,
          outputs_audit_ok: true,
          inputs_audit_ok: true,
          utxo_audit_ok: true,
          node_inputs_count: 7_844,
          db_inputs_count: 7_844,
          expected_live_outputs_count: 7_775,
          actual_live_utxos_count: 7_775,

          stage_timings: {
            rpc_getblockhash: 1,
            rpc_getblock_header: 33,
            prepare_block_buffer: 42,
            block_processor: 2_134,
            flush_buffers_until_empty: 95_196,
            reconcile_spent_outputs: 136,
            audit_outputs: 956,
            audit_inputs: 616,
            audit_utxo_state: 538,
            strict_output_facts: 63,
            register_tx_output_projection: 88,
            register_tx_outputs_async_sync: 41,
            final_counts: 6
          },

          flush_metrics: {
            version: 1,
            iterations_count: 1,

            outputs: {
              rows_flushed: 11_072,
              duration_ms: 120_000,
              ms_per_row: 10.838,

              stage_timings: {
                create_temp_table: 500,
                copy_rows: 700,
                insert_utxo_outputs: 118_000
              }
            },

            spent: {
              rows_flushed: 8_564,
              duration_ms: 264_000,
              ms_per_row: 30.827,

              stage_timings: {
                create_temp_table: 400,
                copy_rows: 600,
                bulk_upsert_cluster_inputs: 240_000,
                bulk_delete_utxo_outputs: 15_000
              }
            }
          }
        }
      },

      proof: {
        total_checks: 3,
        passed_checks: 3,
        compliance: 100,
        conformant: true
      },

      audit: {
        status: "healthy",
        activity: "idle",
        last_healthy_height: 956_770,
        highest_healthy_height: 956_770
      },

      pace: {
        status: "available",

        comparison: {
          trend: "stable"
        }
      },

      historical_projection: {
        state: "deferred",
        status: "deferred",
        pending_count: 20,
        failed_count: 0,
        projection_lag_blocks: 10,

        outputs: {
          state: "deferred",
          description: "En pause — priorité au temps réel.",
          projection_lag_blocks: 10,
          pending_count: 12,
          failed_count: 0
        },

        spent_sync: {
          state: "deferred",
          description: "En pause — priorité au temps réel.",
          projection_lag_blocks: 8,
          pending_count: 8,
          failed_count: 0
        }
      },

      counts: {
        block_buffers: 2_857,
        utxo_outputs: 88_000_000,
        cluster_inputs: 21_500_000,

        accuracy: {
          block_buffers: "exact",
          utxo_outputs: "estimated",
          cluster_inputs: "estimated"
        }
      },

      cursors: {
        cluster_scanner: 956_753,
        utxo_max_height: 956_774
      },

      queues: {
        "layer1_strict" => 0,
        "layer1_drain" => 0
      }
    }
  end
end
