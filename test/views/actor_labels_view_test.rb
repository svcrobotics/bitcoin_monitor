# frozen_string_literal: true

require "test_helper"

class ActorLabelsViewTest < ActionView::TestCase
  test "renders actor labels as inputs calculations outputs and consumers" do
    render(
      partial: "questions/answers/actor_labels",
      locals: {
        snapshot: snapshot
      }
    )

    assert_includes rendered, "ActorLabels"
    assert_includes rendered, "Classification économique des acteurs"

    assert_includes rendered, "Entrées"
    assert_includes rendered, "Backlog ActorLabels"
    assert_includes rendered, "Retard ActorBehavior"
    assert_includes rendered, "blocs derrière ActorProfile"
    assert_includes rendered, "Origine amont"
    assert_includes rendered, "Entrée directe"
    assert_includes rendered, "ActorProfile"
    assert_includes rendered, "ActorBehavior"
    assert_includes rendered, "strict_v2"

    assert_includes rendered, "Calculs"
    assert_includes rendered, "Sélection des comportements"
    assert_includes rendered, "Contrôle d’éligibilité"
    assert_includes rendered, "Application des règles"
    assert_includes rendered, "Écriture et réconciliation"
    assert_includes rendered, "Non mesurée"

    assert_includes rendered, "Sorties"
    assert_includes rendered, "exchange_like"
    assert_includes rendered, "whale_like"
    assert_includes rendered, "etf_candidate"
    assert_includes rendered, "Zéro label est un résultat valide"

    assert_includes rendered, "Utilisé par"
    assert_includes rendered, "Exchange Flow"
    assert_includes rendered, "SOURCE DISPONIBLE"
    assert_includes rendered, "À CONSTRUIRE"
    assert_includes rendered, "DISPONIBLE"
    assert_includes rendered, "Whale Monitoring"
    assert_includes rendered, "ETF Monitoring"
    assert_includes rendered, "Moteur de réponses Tansa"

    assert_includes rendered, "Voir les détails techniques"
    assert_includes rendered, "25"
    assert_includes rendered, "examinés"
    assert_includes rendered, "label"
    assert_match(/strict_v2<\/span>,/, rendered)
    refute_includes rendered, "Entrées disponibles"
    refute_includes rendered, "Retard de la source"
    assert_includes rendered, "ACTIVE"
  end

  private

  def snapshot
    {
      status: "active",
      reasons: [],
      pipeline: {
        source:
          ActorLabels::StrictRuleSet::SOURCE,
        rule_version:
          ActorLabels::StrictRuleSet::RULE_VERSION,
        required_behavior_version: "strict_v2",
        automatic_write_enabled: true
      },

      actor_behaviors: {
        snapshots_current: 3_137,
        snapshots_missing: 12_627,
        snapshots_stale: 0,
        coverage_percent: 19.9,
        actor_profiles_certified: 15_764,
        actor_profile_max_height: 956_752,
        checkpoint_lag: 69
      },

      actor_labels: {
        total: 2,
        pending_for_labels: 2_007,
        evaluated_cursor: 1_157,
        by_label: {
          "exchange_like" => 1,
          "service_like" => 1
        }
      },

      rules: {
        active: %w[
          whale_like
          whale_candidate
          exchange_like
          service_like
          etf_candidate
        ],
        disabled: %w[
          etf_like
          retail_like
        ]
      },

      automation: {
        queue_name: "actor_labels_strict",
        queue_size: 0,
        worker_present: true,
        worker_busy: false,
        lock_present: false,
        cooldown_active: true,
        cooldown_remaining_seconds: 10,
        last_run_finished_at:
          Time.zone.parse("2026-07-05 11:40:37"),
        last_runtime_ms: 14_527,

        last_run: {
          "batch" => {
            "limit" => 25,
            "scanned" => 25,
            "eligible" => 25,
            "ineligible" => 0,
            "snapshots_with_labels" => 2,
            "snapshots_without_labels" => 23,
            "expected_labels" => 2,
            "expected_by_label" => {
              "exchange_like" => 1,
              "service_like" => 1
            },
            "written_labels" => 2,
            "deleted_labels" => 0,
            "failed" => 0
          },
          "rejected_by_reason" => {}
        }
      }
    }
  end
end
