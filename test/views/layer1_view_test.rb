# frozen_string_literal: true

require "test_helper"

class Layer1ViewTest < ActionView::TestCase
  include Rails.application.routes.url_helpers

  test "renders the three Layer1 subsystems" do
    html = render_layer1(snapshot: overview_snapshot)

    assert_includes html, "01 / Temps réel strict"
    assert_includes html, "02 / Projections historiques"
    assert_includes html, "03 / Audit lourd"
    assert_includes html, "04 / Cadence et origine du retard"
  end

  test "realtime status remains independent from failed audit and projection" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            realtime: realtime_snapshot(status: "healthy"),
            historical_projection:
              historical_projection_snapshot(status: "failed"),
            audit: audit_snapshot(status: "critical")
          )
      )

    assert_match(/01 \/ Temps réel strict.*?HEALTHY/m, html)
    assert_match(/02 \/ Projections historiques.*?FAILED/m, html)
    assert_match(/03 \/ Audit lourd.*?CRITICAL/m, html)
  end

  test "unavailable projection and audit do not prevent rendering" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            historical_projection:
              historical_projection_snapshot(status: "unavailable"),
            audit:
              audit_snapshot(status: "unavailable", activity: "unavailable")
          )
      )

    assert_includes html, "Données de projection indisponibles"
    assert_includes html, "UNAVAILABLE"
    assert_includes html, "01 / Temps réel strict"
  end

  test "checkpoint certified replaces legacy last processed wording" do
    html = render_layer1(snapshot: overview_snapshot)

    assert_includes html, "Checkpoint certifié"
    refute_includes html, "Dernier traité"
  end

  test "views do not reference storage workers or clients directly" do
    sources =
      Rails.root
        .join("app/views/questions/answers")
        .glob("_layer1*.erb")
        .map(&:read) +
      [
        Rails.root
          .join("app/views/layer1_audit/_audit_panel.html.erb")
          .read
      ]

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

  test "manual audit button remains present" do
    html = render_layer1(snapshot: overview_snapshot)

    assert_includes html, "Lancer un audit"
    assert_includes html, system_layer1_audit_run_path
  end

  test "renders expected plural forms" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            realtime:
              realtime_snapshot(
                lag: 1,
                strict_queue_size: 0
              ),
            historical_projection:
              historical_projection_snapshot(
                pending_count: 2
              )
          )
      )

    assert_includes html, "aucun travail"
    assert_includes html, "1 bloc"
    assert_includes html, "2 blocs"
  end

  test "idle processing warning and failed states have visible text" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            realtime:
              realtime_snapshot(
                status: "warning",
                pipeline_state: "idle_synced"
              ),
            historical_projection:
              historical_projection_snapshot(
                status: "processing",
                outputs_status: "processing",
                spent_status: "failed"
              ),
            audit:
              audit_snapshot(
                status: "failed",
                activity: "idle"
              )
          )
      )

    assert_includes html, "WARNING"
    assert_includes html, "PROCESSING"
    assert_includes html, "FAILED"
    assert_includes html, "idle"
  end

  test "renders with partial data" do
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

    assert_includes html, "Layer1"
    assert_includes html, "Temps réel strict"
    assert_includes html, "Projections historiques"
    assert_includes html, "Audit lourd"
    assert_includes html, "Cadence et origine du retard"
    assert_includes html, "DONNÉES INSUFFISANTES"
  end

  test "renders pace panel with data" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            pace:
              pace_snapshot(
                trend: "falling_behind",
                network_seconds: 192,
                layer1_seconds: 304,
                backlog_change: 7.5,
                dominant_stage: "flush"
              )
          )
      )

    assert_includes html, "Cadence Bitcoin"
    assert_includes html, "Certification Layer1"
    assert_includes html, "Accumulation"
    assert_includes html, "7,50 blocs / heure"
    assert_includes html, "RETARD EN HAUSSE"
    assert_includes html, "Goulot actuel"
    assert_includes html, "flush"
  end

  test "renders catching up labels and human catchup estimate" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            pace:
              pace_snapshot(
                trend: "catching_up",
                network_seconds: 320,
                layer1_seconds: 300,
                backlog_change: -0.67,
                estimated_catchup_hours: 84
              )
          )
      )

    assert_includes html, "Rattrapage"
    assert_includes html, "0,67 bloc / heure"
    assert_includes html, "Le retard diminue actuellement."
    assert_includes html, "Rattrapage estimé : environ 3 jours 12 h."
    assert_includes(
      html,
      "Cette estimation reste sensible à la cadence des prochains blocs."
    )
  end

  test "hides precise catchup estimate when net rate is too weak" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            pace:
              pace_snapshot(
                trend: "catching_up",
                network_seconds: 320,
                layer1_seconds: 319,
                backlog_change: -0.2,
                estimated_catchup_hours: 300
              )
          )
      )

    assert_includes html, "Estimation de rattrapage trop instable"
    refute_includes Nokogiri::HTML.fragment(html).text.squish, "300"
  end

  test "renders pace panel without data" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            pace:
              pace_snapshot(
                trend: "insufficient_data",
                network_seconds: nil,
                layer1_seconds: nil,
                backlog_change: nil,
                dominant_stage: nil
              )
          )
      )

    assert_includes html, "DONNÉES INSUFFISANTES"
    assert_includes html, "Données récentes insuffisantes"
  end

  test "renders recent history deltas as human labels" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            pace:
              pace_snapshot(
                recent_blocks: [
                  {
                    height: 956_349,
                    network_interval_seconds: 1200,
                    processing_duration_seconds: 109,
                    delta_seconds: -1091
                  },
                  {
                    height: 956_348,
                    network_interval_seconds: 300,
                    processing_duration_seconds: 639,
                    delta_seconds: 339
                  },
                  {
                    height: 956_347,
                    network_interval_seconds: 300,
                    processing_duration_seconds: 305,
                    delta_seconds: 5
                  }
                ]
              )
          )
      )

    assert_includes html, "Gain de rattrapage"
    assert_includes html, "18 min 11 s"
    assert_includes html, "Retard ajouté"
    assert_includes html, "5 min 39 s"
    assert_includes html, "Cadence équilibrée"
  end

  test "renders historical recovery and counters in French" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            historical_projection:
              historical_projection_snapshot(
                pending_count: 1_354,
                processing_count: 0,
                stale_processing_count: 0,
                failed_count: 0,
                recovery: nil
              )
          )
      )

    assert_includes html, "En attente"
    assert_includes html, "1 354 blocs"
    assert_includes html, "En cours"
    assert_includes html, "Traitements anciens"
    assert_includes html, "Âge du plus ancien traitement"
    assert_includes html, "Prochain bloc"
    assert_includes html, "aucune nécessaire"
    refute_includes html, "non observée"
    refute_includes html, "Processing"
  end

  test "renders observed historical recovery" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            historical_projection:
              historical_projection_snapshot(
                recovery: {
                  recovered: 2
                }
              )
          )
      )

    assert_includes html, "2 records récupérés"
  end

  test "renders last activity as relative time" do
    html =
      render_layer1(
        snapshot:
          overview_snapshot(
            realtime:
              realtime_snapshot(
                last_activity_seconds_ago: 42
              )
          )
      )

    assert_includes html, "Dernière activité"
    assert_includes html, "il y a 42 s"
  end

  test "renders non instrumented database component and component average note" do
    html =
      render_layer1(snapshot: overview_snapshot)

    assert_includes html, "médiane réseau, 30 derniers blocs"
    assert_includes html, "médiane, 30 derniers blocs"
    assert_includes(
      html,
      "Moyenne des composants sur les 10 derniers blocs terminés"
    )
    assert_includes html, "Historique visuel récent — 10 derniers blocs terminés"
    assert_includes html, "DB"
    assert_includes html, "non instrumenté"
    assert_includes html, "Certification médiane"
    assert_includes html, "Certification moyenne"
    assert_includes html, "Part du flush dans le temps total"
    assert_includes html, "Part du flush dans le temps instrumenté"
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
