# frozen_string_literal: true

class CreateActorBehaviorBuildHandoffs < ActiveRecord::Migration[8.0]
  STATUSES = %w[pending processing completed failed].freeze

  def change
    create_table :actor_behavior_build_handoffs do |t|
      t.references :cluster, null: false, foreign_key: true
      t.references :actor_profile, null: false, foreign_key: true
      t.bigint :cluster_composition_version, null: false
      t.string :profile_version, null: false
      t.integer :source_height, null: false
      t.string :source_hash, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :claimed_at
      t.datetime :completed_at
      t.string :last_error_class
      t.timestamps
    end

    add_index :actor_behavior_build_handoffs,
      %i[cluster_id cluster_composition_version profile_version source_height source_hash],
      unique: true,
      name: "idx_actor_behavior_handoffs_identity"
    add_index :actor_behavior_build_handoffs,
      %i[status source_height cluster_id id],
      name: "idx_actor_behavior_handoffs_claim"
    add_index :actor_behavior_build_handoffs, :claimed_at

    add_check_constraint :actor_behavior_build_handoffs,
      "cluster_composition_version >= 1",
      name: "actor_behavior_handoffs_positive_composition"
    add_check_constraint :actor_behavior_build_handoffs,
      "source_height >= 0",
      name: "actor_behavior_handoffs_nonnegative_height"
    add_check_constraint :actor_behavior_build_handoffs,
      "profile_version <> ''",
      name: "actor_behavior_handoffs_profile_version_present"
    add_check_constraint :actor_behavior_build_handoffs,
      "source_hash <> ''",
      name: "actor_behavior_handoffs_source_hash_present"
    add_check_constraint :actor_behavior_build_handoffs,
      "status IN (#{STATUSES.map { |status| connection.quote(status) }.join(', ')})",
      name: "actor_behavior_handoffs_status_valid"
    add_check_constraint :actor_behavior_build_handoffs,
      "attempts >= 0",
      name: "actor_behavior_handoffs_attempts_nonnegative"
  end
end
