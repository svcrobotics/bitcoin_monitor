# frozen_string_literal: true

require "test_helper"

class ActorLabelsHeavyViewTest <
  ActionView::TestCase

  test "renders positive and rejected heavy evidence" do
    render(
      partial:
        "questions/answers/actor_labels_heavy",

      locals: {
        heavy:
          heavy_snapshot
      }
    )

    assert_includes(
      rendered,
      "Analyse comportementale approfondie"
    )

    assert_includes(
      rendered,
      "Candidat infrastructure d’exchange"
    )

    assert_includes(
      rendered,
      "Infrastructure d’exchange non confirmée"
    )

    assert_includes(
      rendered,
      "LABEL PUBLIÉ"
    )

    assert_includes(
      rendered,
      "AUCUN LABEL"
    )

    assert_match(
      /43[,.]41/,
      rendered
    )

    assert_includes(
      rendered,
      "Identité non vérifiée"
    )

    assert_includes(
      rendered,
      "exchange_infrastructure_heavy_v2"
    )

    assert_includes(
      rendered,
      "exchange_infrastructure_score_v2"
    )
  end

  private

  def heavy_snapshot
    {
      status: "active",
      analyzed: 2,
      candidates: 1,
      rejected: 1,
      labels_published: 1,

      minimum_sweep_share_percent:
        80.0,

      cases: [
        {
          source_cluster_id:
            21_885,

          downstream_cluster_id:
            932_417,

          candidate: true,
          label_published: true,
          confidence: 90,
          infrastructure_score: 100,
          sweep_score: 100,
          sweep_share_percent: 100.0,

          consolidation_transactions:
            447,

          distribution_transactions:
            2_613,

          batch_percent:
            98.51,

          external_addresses:
            31_382,

          external_clusters:
            3_885,

          window_from_height:
            953_901,

          window_to_height:
            956_900,

          heavy_version:
            "exchange_infrastructure_heavy_v2",

          builder_version:
            "actor_behavior_heavy_build_v2",

          score_version:
            "exchange_infrastructure_score_v2"
        },

        {
          source_cluster_id:
            2_877,

          downstream_cluster_id:
            5_337,

          candidate: false,
          label_published: false,
          confidence: 0,
          infrastructure_score: 92,
          sweep_score: 69,
          sweep_share_percent: 43.41,

          consolidation_transactions:
            462,

          distribution_transactions:
            158,

          batch_percent:
            56.96,

          external_addresses:
            599,

          external_clusters:
            224,

          window_from_height:
            953_901,

          window_to_height:
            956_900,

          heavy_version:
            "exchange_infrastructure_heavy_v2",

          builder_version:
            "actor_behavior_heavy_build_v2",

          score_version:
            "exchange_infrastructure_score_v2"
        }
      ]
    }
  end
end
