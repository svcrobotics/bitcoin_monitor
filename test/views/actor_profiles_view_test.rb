# frozen_string_literal: true

require "test_helper"

class ActorProfilesViewTest < ActionView::TestCase
  test "renders actor profile as inputs calculations outputs and consumers" do
    render(
      partial: "questions/answers/actor_profiles",
      locals: {
        snapshot: snapshot
      }
    )

    assert_includes rendered, "ActorProfile"
    assert_includes rendered, "Profils économiques certifiés"

    assert_includes rendered, "Entrées"
    assert_includes rendered, "Entrée directe"
    assert_includes rendered, "Cluster certifié"
    assert_includes rendered, "Tables strictes réellement lues"
    assert_includes rendered, "addresses"
    assert_includes rendered, "cluster_inputs"
    assert_includes rendered, "utxo_outputs"

    assert_includes rendered, "Calculs"
    assert_includes rendered, "Sélection des clusters"
    assert_includes rendered, "Agrégation des sources"
    assert_includes rendered, "Calcul des faits économiques"
    assert_includes rendered, "Certification du profil"
    assert_includes rendered, "25 construits"
    assert_includes rendered, "Temps moyen"

    assert_includes rendered, "Sorties"
    assert_includes rendered, "Faits économiques publiés"
    assert_includes rendered, "strict_v4_core_facts"
    assert_includes rendered, "balance_btc"
    assert_includes rendered, "activity_span_blocks"
    assert_includes rendered, "metadata.strict = true"
    assert_includes rendered, "epoch_active = true"
    assert_includes rendered, "certification_epoch_height"
    assert_includes rendered, "certification_scope"
    assert_includes rendered, "activity_since_epoch"
    assert_includes rendered, "certified_at présent"
    assert_includes rendered, "Époque de certification"
    assert_includes rendered, "Bloc de départ"
    assert_includes rendered, "historiques hors époque"
    assert_includes rendered, "ActorProfile publie des"

    assert_includes rendered, "Utilisé par"
    assert_includes rendered, "ActorBehavior"
    assert_includes rendered, "SOURCE DIRECTE"
    assert_includes rendered, "ActorLabels"
    assert_includes rendered, "SOURCE INDIRECTE"
    assert_includes rendered, "Moteur de réponses Tansa"

    assert_includes rendered, "Backlog ActorProfile"
    assert_includes rendered, "Retard Cluster"
    assert_includes rendered, "Voir les détails techniques"
    assert_includes rendered, "PIPELINE EN ALTERNANCE"
  end

  private

  def snapshot
    {
      available: true,
      status: "syncing",

      strict: {
        status: "syncing",

        sync: {
          layer1_tip: 956_772,
          cluster_tip: 956_752,
          strict_tips_aligned: false,
          profile_max_height: 956_752,
          certified_profile_max_height: 956_752,
          current_height_profiles: 15_800
        },

        progress: {
          total_clusters: 422_700,
          profiles_in_scope: 15_900,
          actor_profiles: 15_900,
          missing_profiles: 406_775,
          stale_profiles: 25,
          certified_profiles: 15_900,
          pending_profiles: 406_800,
          completion_pct: 3.76
        },

        certification: {
          required_profile_version:
            "strict_v4_core_facts",
          strict_core_profiles: 15_900,
          certified_profiles: 15_900,
          dirty_profiles: 0,
          composition_mismatches: 0,
          height_stale_profiles: 25,
          provenance_mismatches: 0
        },

        integrity: {
          invalid_profile_refs: 0,
          profile_partition_delta: 0,
          profile_partition_ok: true
        },

        freshness: {
          profiles_last_10m: 125,
          profiles_last_1h: 750
        },

        issues: [
          "strict_tips_not_aligned=956752/956772"
        ]
      },

      activity: {
        pipeline_state: "scheduled",
        wait_reason: nil
      },

      automation: {
        queue_name: "actor_profile_strict",
        process_present: true,
        process_count: 1,
        busy_workers: 0,
        queue_size: 0,
        scheduled_jobs: 1,
        lock_ttl: -2,
        schedule_marker_ttl: 25,
        retries: 0,
        dead_jobs: 0,
        automation_ok: true
      },

      last_batch: {
        completed_at:
          Time.zone.parse("2026-07-05 13:20:00"),
        selected: 25,
        built: 25,
        deferred: 0,
        failed: 0,
        duration_ms: 18_750,
        avg_runtime_ms: 750,
        min_runtime_ms: 410,
        max_runtime_ms: 1_920,
        cluster_tip: 956_752
      },

      recent_batches: [
        {
          selected: 25,
          built: 25,
          deferred: 0,
          failed: 0,
          duration_ms: 18_750,
          cluster_tip: 956_752
        }
      ],

      issues: []
    }
  end
end
