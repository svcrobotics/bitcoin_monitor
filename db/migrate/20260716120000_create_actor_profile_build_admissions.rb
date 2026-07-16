# frozen_string_literal: true

class CreateActorProfileBuildAdmissions < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_profile_build_admissions do |t|
      t.references :cluster, null: false, foreign_key: true
      t.bigint :cluster_composition_version, null: false
      t.bigint :source_height, null: false
      t.string :source_hash, null: false
      t.string :reason, null: false
      t.string :status, default: "pending", null: false
      t.integer :attempts, default: 0, null: false
      t.datetime :claimed_at, precision: 6
      t.datetime :completed_at, precision: 6
      t.string :last_error_class
      t.timestamps
    end

    add_index :actor_profile_build_admissions,
      [ :cluster_id, :cluster_composition_version, :source_height, :source_hash ],
      unique: true,
      name: "idx_actor_profile_admissions_identity"
    add_index :actor_profile_build_admissions,
      [ :status, :source_height, :cluster_id, :id ],
      name: "idx_actor_profile_admissions_claim_order"

    add_check_constraint :actor_profile_build_admissions,
      "cluster_composition_version >= 1",
      name: "actor_profile_admissions_composition_version_check"
    add_check_constraint :actor_profile_build_admissions,
      "source_height >= 0",
      name: "actor_profile_admissions_source_height_check"
    add_check_constraint :actor_profile_build_admissions,
      "source_hash <> ''",
      name: "actor_profile_admissions_source_hash_check"
    add_check_constraint :actor_profile_build_admissions,
      "reason <> ''",
      name: "actor_profile_admissions_reason_check"
    add_check_constraint :actor_profile_build_admissions,
      "attempts >= 0",
      name: "actor_profile_admissions_attempts_check"
    add_check_constraint :actor_profile_build_admissions,
      "status IN ('pending', 'processing', 'completed', 'failed')",
      name: "actor_profile_admissions_status_check"
    add_check_constraint :actor_profile_build_admissions,
      "status <> 'processing' OR claimed_at IS NOT NULL",
      name: "actor_profile_admissions_claim_check"
    add_check_constraint :actor_profile_build_admissions,
      "(status = 'completed' AND completed_at IS NOT NULL) OR " \
      "(status <> 'completed' AND completed_at IS NULL)",
      name: "actor_profile_admissions_completion_check"
  end
end
