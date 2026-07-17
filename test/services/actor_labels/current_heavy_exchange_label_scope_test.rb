# frozen_string_literal: true

require "test_helper"

module ActorLabels
  class CurrentHeavyExchangeLabelScopeTest <
    ActiveSupport::TestCase

    test "excludes an orphaned heavy exchange label" do
      cluster =
        Cluster.create!

      label =
        ActorLabel.create!(
          cluster: cluster,
          label:
            "exchange_infrastructure_candidate",
          source:
            ActorLabels::HeavyRuleSet::SOURCE,
          confidence: 90,
          metadata: {
            actor_behavior_heavy_snapshot_id:
              999_999
          }
        )

      scope =
        ActorLabels::
          CurrentHeavyExchangeLabelScope
          .call

      refute_includes scope, label

      result =
        ActorLabels::FinalResolutionSnapshot.call(
          strict_rows: []
        )

      refute_includes(
        result[:exchange_clusters],
        cluster.id
      )

      sql =
        scope.to_sql

      [
        "actor_behavior_heavy_snapshots.id::text",
        "actor_behavior_heavy_snapshot_id",
        "status = 'certified'",
        "exchange_infrastructure_heavy_v2",
        "exchange_infrastructure_candidate"
      ].each do |fragment|
        assert_includes sql, fragment
      end
    end
  end
end
