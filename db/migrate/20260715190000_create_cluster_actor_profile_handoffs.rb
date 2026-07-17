# frozen_string_literal: true

class CreateClusterActorProfileHandoffs < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_actor_profile_handoffs do |t|
      t.bigint :cluster_height, null: false
      t.string :block_hash, null: false
      t.references :cluster, null: false, foreign_key: true
      t.bigint :composition_version, null: false
      t.string :status, default: "pending", null: false
      t.integer :attempts, default: 0, null: false
      t.string :last_error_class
      t.datetime :claimed_at, precision: 6
      t.datetime :completed_at, precision: 6
      t.timestamps
    end

    add_index :cluster_actor_profile_handoffs,
      [ :cluster_height, :block_hash, :cluster_id, :composition_version ],
      unique: true,
      name: "idx_cluster_actor_handoffs_certification_version"
    add_index :cluster_actor_profile_handoffs,
      [ :status, :cluster_height, :cluster_id ],
      name: "idx_cluster_actor_handoffs_claim_order"
    add_index :cluster_actor_profile_handoffs,
      [ :cluster_height, :block_hash ],
      name: "idx_cluster_actor_handoffs_height_hash"

    add_check_constraint :cluster_actor_profile_handoffs,
      "cluster_height >= 0",
      name: "cluster_actor_handoffs_height_check"
    add_check_constraint :cluster_actor_profile_handoffs,
      "composition_version >= 1",
      name: "cluster_actor_handoffs_version_check"
    add_check_constraint :cluster_actor_profile_handoffs,
      "attempts >= 0",
      name: "cluster_actor_handoffs_attempts_check"
    add_check_constraint :cluster_actor_profile_handoffs,
      "status IN ('pending', 'processing', 'completed', 'failed')",
      name: "cluster_actor_handoffs_status_check"
    add_check_constraint :cluster_actor_profile_handoffs,
      "(status = 'completed' AND completed_at IS NOT NULL) OR " \
      "(status <> 'completed' AND completed_at IS NULL)",
      name: "cluster_actor_handoffs_completion_check"
    add_check_constraint :cluster_actor_profile_handoffs,
      "status <> 'processing' OR claimed_at IS NOT NULL",
      name: "cluster_actor_handoffs_claim_check"
  end
end
