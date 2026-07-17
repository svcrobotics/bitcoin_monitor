# frozen_string_literal: true

class CreateActorLabelHandoffs < ActiveRecord::Migration[8.0]
  STATUSES = %w[pending processing completed failed].freeze

  def change
    create_table :actor_label_handoffs do |t|
      t.references :cluster, null: false, foreign_key: true
      t.references :actor_behavior_snapshot, null: false, foreign_key: true
      t.bigint :cluster_composition_version, null: false
      t.string :profile_version, null: false
      t.bigint :source_height, null: false
      t.string :source_hash, null: false
      t.string :behavior_version, null: false
      t.string :rule_version, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :claimed_at
      t.datetime :completed_at
      t.string :last_error_class
      t.timestamps
    end

    add_index :actor_label_handoffs,
      %i[cluster_id cluster_composition_version profile_version source_height source_hash behavior_version actor_behavior_snapshot_id rule_version],
      unique: true, name: "idx_actor_label_handoffs_identity"
    add_index :actor_label_handoffs, %i[status source_height cluster_id id],
      name: "idx_actor_label_handoffs_claim"
    add_index :actor_label_handoffs, :claimed_at
    add_check_constraint :actor_label_handoffs, "cluster_composition_version >= 1",
      name: "actor_label_handoffs_composition_positive"
    add_check_constraint :actor_label_handoffs, "source_height >= 0",
      name: "actor_label_handoffs_height_nonnegative"
    %i[profile_version source_hash behavior_version rule_version].each do |column|
      add_check_constraint :actor_label_handoffs, "#{column} <> ''",
        name: "actor_label_handoffs_#{column}_present"
    end
    add_check_constraint :actor_label_handoffs, "attempts >= 0",
      name: "actor_label_handoffs_attempts_nonnegative"
    add_check_constraint :actor_label_handoffs,
      "status IN (#{STATUSES.map { |status| connection.quote(status) }.join(', ')})",
      name: "actor_label_handoffs_status_valid"
  end
end
