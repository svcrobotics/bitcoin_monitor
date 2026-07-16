# frozen_string_literal: true

class ContractCertifiedActorBehaviorSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :actor_behavior_snapshots, :source_hash, :string
    add_column :actor_behavior_snapshots, :certification_scope, :string
    add_column :actor_behavior_snapshots, :certified_at, :datetime

    add_index :actor_behavior_snapshots,
      %i[cluster_id cluster_composition_version profile_version profile_height source_hash],
      name: "idx_actor_behavior_snapshots_strict_identity"
    add_index :actor_behavior_snapshots, :certified_at

    add_check_constraint :actor_behavior_snapshots,
      "status <> 'certified' OR (source_hash IS NOT NULL AND source_hash <> '' " \
      "AND certification_scope = 'strict' AND certified_at IS NOT NULL)",
      name: "actor_behavior_snapshots_certified_provenance",
      validate: false
  end
end
