# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class SnapshotStateScopeTest < ActiveSupport::TestCase
    test "current snapshots require strict certified provenance" do
      sql =
        ActorBehaviors::SnapshotStateScope
          .new
          .current_condition_sql

      assert_includes sql, "actor_behavior_snapshots.source_hash IS NOT NULL"
      assert_includes sql, "actor_behavior_snapshots.source_hash <> ''"
      assert_includes sql,
        "actor_behavior_snapshots.certification_scope = 'strict'"
      assert_includes sql, "actor_behavior_snapshots.certified_at IS NOT NULL"
    end
  end
end
