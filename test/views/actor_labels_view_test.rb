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

    [
      "ActorLabels",
      "Classification économique des acteurs",
      "Entrées",
      "Backlog ActorLabels",
      "Retard ActorBehavior",
      "blocs derrière ActorProfile",
      "Origine amont",
      "Entrée directe",
      "ActorProfile",
      "ActorBehavior",
      "strict_v2",
      "Calculs",
      "Sélection des comportements",
      "Contrôle d’éligibilité",
      "Application des règles",
      "Écriture et réconciliation",
      "Non mesurée",
      "Sorties ActorLabels",
      "Entrées contractuelles des modules aval",
      "Exchange Flow",
      "Whale Flow",
      "Service Flow",
      "ETF Flow",
      "exchange_infrastructure_candidate",
      "whale_like",
      "service_infrastructure",
      "etf_like",
      "Les modules peuvent être construits avant l’arrivée des données.",
      "Voir les signaux internes et la résolution détaillée",
      "Voir les détails techniques",
      "25",
      "examinés",
      "label",
      "ACTIVE"
    ].each do |label|
      assert_includes rendered, label
    end

    refute_includes rendered, "Entrées disponibles"
    refute_includes rendered, "Retard de la source"
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
