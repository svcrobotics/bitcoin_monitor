# frozen_string_literal: true

class DropActorProfileDeltas < ActiveRecord::Migration[8.0]
  def up
    drop_table :actor_profile_deltas, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "actor_profile_deltas appartenait au pipeline ActorProfile legacy supprimé"
  end
end
