# frozen_string_literal: true

require "test_helper"

class Layer1ViewTest < ActionView::TestCase
  include Rails.application.routes.url_helpers

  test "renders the recovered Layer1 mental model" do
    html = render_layer1(snapshot: overview_snapshot)

    [
      "Infrastructure Bitcoin stricte",
      "Entrées",
      "Données reçues depuis Bitcoin Core",
      "Calculs temps réel",
      "Certification stricte d’un bloc",
      "Sorties certifiées",
      "Faits Bitcoin publiés",
      "Utilisé par",
      "Modules alimentés par Layer1",
      "Travaux asynchrones",
      "Historique et audits lourds"
    ].each do |label|
      assert_includes html, label
    end
  end

  test "renders strict inputs and processing stages" do
    html = render_layer1(snapshot: overview_snapshot)

    [
      "Bitcoin Core RPC",
      "block_buffers",
      "Buffer outputs",
      "Buffer spent",
      "Lecture Bitcoin Core",
      "Préparation du bloc",
      "Traitement des transactions",
      "Matérialisation PostgreSQL",
      "Réconciliation",
      "Audits stricts",
      "Publication des faits"
    ].each do |label|
      assert_includes html, label
    end
  end

  test "renders certified outputs and downstream consumers" do
    html = render_layer1(snapshot: overview_snapshot)

    [
      "utxo_outputs",
      "cluster_inputs",
      "Dernier bloc certifié",
      "Audit outputs",
      "Audit inputs",
      "Audit état UTXO",
      "Cluster",
      "ActorProfile",
      "Modules analytiques",
      "Moteur Tansa"
    ].each do |label|
      assert_includes html, label
    end
  end

  test "renders asynchronous projections audit and pace" do
    html = render_layer1(snapshot: overview_snapshot)

    [
      "Projection tx_outputs",
      "Synchronisation tx_outputs.spent",
      "Audit lourd indépendant",
      "Rythme de certification",
      "Voir les détails techniques"
    ].each do |label|
      assert_includes html, label
    end
  end

  test "renders catchup pilotage from the current contract" do
    html = render_layer1(snapshot: overview_snapshot)

    assert_includes html, "data-layer1-catchup-indicators"
    assert_includes html, "Pilotage du rattrapage"
    assert_includes html, "Lag actuel"
    assert_includes html, "Bitcoin Core"
  end

  test "renders human block counters" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            realtime:
              realtime_snapshot(
                lag: 1
              ),
            historical_projection:
              historical_projection_snapshot(
                pending_count: 1_354
              )
          )
      )

    text = Nokogiri::HTML.fragment(html).text.squish

    assert_match(/Retard\s+1 bloc/, text)
    assert_match(/En attente\s+1 354/, text)
  end

  test "renders safely with partial data" do
    html =
      render_layer1(
        snapshot: {
          source: "layer1_overview_snapshot",
          realtime: {
            status: "healthy",
            processed_height: 956_341
          },
          historical_projection: {
            status: "unavailable"
          },
          audit: {
            status: "unavailable"
          }
        }
      )

    assert_includes html, "Infrastructure Bitcoin stricte"
    assert_includes html, "Données reçues depuis Bitcoin Core"
    assert_includes html, "Faits Bitcoin publiés"
    assert_includes html, "Historique et audits lourds"
  end

  test "manual audit action remains present" do
    html = render_layer1(snapshot: overview_snapshot)

    assert_includes html, "Lancer un audit"
    assert_includes html, system_layer1_audit_run_path
  end

  test "rendered Layer1 views do not access storage clients directly" do
    sources = %w[
      _layer1.html.erb
      _layer1_pipeline.html.erb
      _layer1_catchup_indicators.html.erb
    ].map do |filename|
      Rails.root
        .join("app/views/questions/answers", filename)
        .read
    end

    forbidden = %w[
      Layer1AuditRun
      Layer1TxOutputSync
      Layer1TxOutputProjectionBlock
      BlockBufferModel
      Sidekiq::Queue
      Sidekiq::ProcessSet
      Redis
      BitcoinRpc
    ]

    forbidden.each do |constant|
      sources.each do |source|
        refute_includes source, constant
      end
    end
  end

  private

  def render_layer1(snapshot:)
    render partial: "questions/answers/layer1",
           locals: {
             snapshot: snapshot
           }

    rendered
  end

  def overview_snapshot(
    realtime: realtime_snapshot,
    historical_projection: historical_projection_snapshot,
    audit: audit_snapshot,
    pace: pace_snapshot
  )
    {
      source: "layer1_overview_snapshot",
      realtime: realtime,
      historical_projection: historical_projection,
      audit: audit,
      pace: pace
    }
  end

  def realtime_snapshot(
    status: "healthy",
    lag: 0,
    pipeline_state: "idle_synced",
    strict_queue_size: 0,
    last_activity_seconds_ago: nil
  )
    {
      status: status,
      bitcoin_core_height: 956_354,
      processed_height: 956_341,
      lag: lag,
      sync: {
        bitcoin_core_height: 956_354,
        processed_height: 956_341,
        lag: lag
      },
      buffers: {
        outputs: 0,
        spent: 0
      },
      activity: {
        pipeline_state: pipeline_state,
        current_height: nil,
        last_processed_at: Time.current,
        last_activity_at: Time.current,
        last_activity_seconds_ago: last_activity_seconds_ago
      },
      strict: {
        worker: {
          present: true,
          busy: 0,
          process_count: 1
        },
        scheduler: {
          registered: true,
          enabled: true,
          status: "enabled"
        },
        scheduler_process: {
          present: true
        },
        queue_size: strict_queue_size,
        processing_block: nil
      },
      issues: []
    }
  end

  def historical_projection_snapshot(
    status: "synced",
    outputs_status: status,
    spent_status: status,
    pending_count: 0,
    processing_count: 0,
    stale_processing_count: 0,
    failed_count: nil,
    recovery: nil
  )
    {
      status: status,
      outputs: {
        status: outputs_status,
        enabled: true,
        last_projected_height: 956_341,
        projection_lag_blocks: 0,
        pending_count: pending_count,
        processing_count: processing_count,
        stale_processing_count: stale_processing_count,
        failed_count: failed_count.nil? ? (outputs_status == "failed" ? 1 : 0) : failed_count,
        recovery: recovery,
        queue_size: 0,
        worker: {
          present: true,
          busy: outputs_status == "processing" ? 1 : 0
        }
      },
      spent_sync: {
        status: spent_status,
        enabled: true,
        last_synced_height: 956_341,
        projection_lag_blocks: 0,
        pending_count: pending_count,
        processing_count: processing_count,
        stale_processing_count: stale_processing_count,
        failed_count: failed_count.nil? ? (spent_status == "failed" ? 1 : 0) : failed_count,
        recovery: recovery,
        queue_size: 0,
        worker: {
          present: true,
          busy: spent_status == "processing" ? 1 : 0
        }
      }
    }
  end

  def audit_snapshot(status: "healthy", activity: "idle")
    {
      status: status,
      activity: activity,
      last_attempted_height: 956_340,
      last_healthy_height: 956_340,
      highest_healthy_height: 956_340,
      queue: {
        size: 0
      },
      busy_workers: activity == "running" ? 1 : 0,
      recent_runs: {
        sample_size: 1,
        healthy: status == "healthy" ? 1 : 0,
        failed: status == "failed" ? 1 : 0,
        errors: 0
      },
      last_run: {
        status: status,
        duration_seconds: 1.2
      }
    }
  end

  def pace_snapshot(
    trend: "catching_up",
    network_seconds: 600,
    layer1_seconds: 300,
    backlog_change: -6.0,
    dominant_stage: "flush",
    estimated_catchup_hours: nil,
    recent_blocks: nil
  )
    {
      sample: {
        processing_blocks: 30,
        network_intervals: 29
      },
      network: {
        median_interval_seconds: network_seconds,
        average_interval_seconds: network_seconds,
        blocks_per_hour:
          network_seconds.present? ? 3600.0 / network_seconds : nil
      },
      ingestion: {
        median_interval_seconds: 30,
        average_interval_seconds: 32
      },
      processing: {
        current_height: 956_350,
        current_elapsed_seconds: 120,
        last_height: 956_349,
        last_duration_seconds: layer1_seconds,
        median_10_seconds: layer1_seconds,
        average_10_seconds: layer1_seconds,
        median_30_seconds: layer1_seconds,
        average_30_seconds: layer1_seconds,
        minimum_30_seconds: layer1_seconds,
        maximum_30_seconds: layer1_seconds,
        slowest_height: 956_349
      },
      components: {
        rpc_average_seconds: 0.5,
        parse_average_seconds: 0.1,
        db_average_seconds: nil,
        flush_average_seconds: 288,
        unattributed_average_seconds: 3.2,
        average_duration_seconds: layer1_seconds,
        flush_percent: 94.7,
        flush_total_percent: 94.7,
        flush_instrumented_percent: 98.7,
        dominant_stage: dominant_stage
      },
      comparison: {
        pace_ratio:
          if network_seconds.present? && layer1_seconds.present?
            layer1_seconds.to_f / network_seconds
          end,
        layer1_blocks_per_hour:
          layer1_seconds.present? ? 3600.0 / layer1_seconds : nil,
        network_blocks_per_hour:
          network_seconds.present? ? 3600.0 / network_seconds : nil,
        backlog_change_per_hour: backlog_change,
        trend: trend,
        estimated_catchup_hours: estimated_catchup_hours,
        current_lag: 62
      },
      recent_blocks:
        recent_blocks ||
        (
          network_seconds.present? && layer1_seconds.present? ?
          [
            {
              height: 956_349,
              network_interval_seconds: network_seconds,
              processing_duration_seconds: layer1_seconds,
              delta_seconds: layer1_seconds - network_seconds
            }
          ] :
          []
        )
    }
  end
end
