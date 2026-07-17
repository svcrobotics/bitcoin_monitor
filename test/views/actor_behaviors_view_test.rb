# frozen_string_literal: true

require "test_helper"

class ActorBehaviorsViewTest < ActionView::TestCase
  test "renders actor behavior as inputs calculations outputs and consumers" do
    render(
      partial: "questions/answers/actor_behaviors",
      locals: {
        snapshot: snapshot
      }
    )

    assert_includes rendered, "ActorBehavior"
    assert_includes rendered, "Comportements observables des acteurs"

    assert_includes rendered, "Entrées"
    assert_includes rendered, "Entrée directe"
    assert_includes rendered, "ActorProfile certifié"
    assert_includes rendered, "Faits réellement utilisés"
    assert_includes rendered, "balance_btc"
    assert_includes rendered, "cluster_composition_version"

    assert_includes rendered, "Calculs"
    assert_includes rendered, "Sélection du travail"
    assert_includes rendered, "Validation de la source"
    assert_includes rendered, "Calcul des scores et signaux"
    assert_includes rendered, "Certification du snapshot"
    assert_includes rendered, "Non mesurée"
    assert_includes rendered, "layer1_realtime_priority"

    assert_includes rendered, "Sorties"
    assert_includes rendered, "Snapshots comportementaux certifiés"
    assert_includes rendered, "whale_score"
    assert_includes rendered, "exchange_score"
    assert_includes rendered, "service_score"
    assert_includes rendered, "etf_score"
    assert_includes rendered, "whale_like_candidate_inputs"
    assert_includes rendered, "retail_like_candidate_inputs"
    assert_includes rendered, "ActorBehavior ne produit pas directement de labels"

    assert_includes rendered, "Utilisé par"
    assert_includes rendered, "ActorLabels"
    assert_includes rendered, "Moteur de réponses Tansa"
    assert_includes rendered, "Analyse Whale"
    assert_includes rendered, "SOURCE DISPONIBLE"

    assert_includes rendered, "Backlog ActorBehavior"
    assert_includes rendered, "Retard ActorBehavior"
    assert_includes rendered, "Voir les détails techniques"
    assert_includes rendered, "BACKFILL EN COURS"
  end

  private

  def snapshot
    {
      status: "shadow_building",
      phase: "shadow",
      ready: false,

      reasons: [
        "behavior_backfill_in_progress",
        "missing_behavior_snapshots"
      ],

      operational: {
        mode: "shadow",
        behavior_version: "strict_v2",

        actor_profiles_certified: 15_873,
        snapshots_current: 3_137,
        snapshots_missing: 12_736,
        snapshots_stale: 0,
        snapshots_non_certified_status: 0,

        coverage_percent: 19.76,

        actor_profile_max_height: 956_752,
        behavior_snapshot_max_height: 956_683,
        checkpoint_lag: 69,

        last_run_status: "completed",
        last_run_duration_ms: 1_145,
        last_run_finished_at:
          Time.zone.parse("2026-07-05 12:15:53"),

        last_run_counts: {
          selected: 25,
          missing_selected: 25,
          stale_selected: 0,
          created: 0,
          updated: 0,
          unchanged: 0,
          deferred: 25,
          failed: 0
        },

        last_run_reasons: {
          "layer1_realtime_priority" => 25
        },

        coverage_invariant_ok: true
      },

      control: {
        mode: "shadow",
        behavior_version: "strict_v2",
        auto_enabled: true,
        scheduler_present: true,
        scheduler_runtime_fresh: true,
        scheduler_actor_behavior_auto_enabled: true,
        batch_running: false,
        cooldown_active: true,
        cooldown_remaining_seconds: 43
      }
    }
  end
end
