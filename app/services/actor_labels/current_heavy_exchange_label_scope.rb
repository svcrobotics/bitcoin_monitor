# frozen_string_literal: true

module ActorLabels
  class CurrentHeavyExchangeLabelScope
    LABEL =
      "exchange_infrastructure_candidate"

    SOURCE =
      ActorLabels::HeavyRuleSet::SOURCE

    ANALYSIS_KIND =
      ActorBehaviors::Heavy::
        BuildFromEvidence::
        ANALYSIS_KIND

    CURRENT_HEAVY_VERSION =
      ActorBehaviors::Heavy::
        BuildFromEvidence::
        HEAVY_VERSION

    def self.call
      ActorLabel
        .where(
          source: SOURCE,
          label: LABEL
        )
        .where(
          <<~SQL.squish,
            EXISTS (
              SELECT 1
              FROM actor_behavior_heavy_snapshots
              WHERE actor_behavior_heavy_snapshots.id::text =
                actor_labels.metadata ->>
                  'actor_behavior_heavy_snapshot_id'
                AND actor_behavior_heavy_snapshots.cluster_id =
                  actor_labels.cluster_id
                AND actor_behavior_heavy_snapshots.status =
                  'certified'
                AND actor_behavior_heavy_snapshots.analysis_kind = ?
                AND actor_behavior_heavy_snapshots.heavy_version = ?
                AND COALESCE(
                  actor_behavior_heavy_snapshots.signals ->>
                    'exchange_infrastructure_candidate',
                  'false'
                ) = 'true'
            )
          SQL
          ANALYSIS_KIND,
          CURRENT_HEAVY_VERSION
        )
    end
  end
end
