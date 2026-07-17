# frozen_string_literal: true

class CreateActorLabelEvaluations < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_label_evaluations do |t|
      t.references :cluster, null: false, foreign_key: true
      t.references :actor_behavior_snapshot, null: false, foreign_key: true
      t.bigint :cluster_composition_version, null: false
      t.string :profile_version, null: false
      t.bigint :source_height, null: false
      t.string :source_hash, null: false
      t.string :behavior_version, null: false
      t.string :rule_version, null: false
      t.string :status, null: false
      t.string :certification_scope, null: false
      t.jsonb :rule_results, null: false, default: {}
      t.jsonb :active_rules, null: false, default: []
      t.jsonb :deferred_rules, null: false, default: []
      t.datetime :certified_at, null: false
      t.timestamps
    end
    add_index :actor_label_evaluations,
      %i[cluster_id cluster_composition_version profile_version source_height source_hash behavior_version actor_behavior_snapshot_id rule_version],
      unique: true, name: "idx_actor_label_evaluations_identity"
    add_index :actor_label_evaluations, :certified_at
    add_check_constraint :actor_label_evaluations, "cluster_composition_version >= 1",
      name: "actor_label_evaluations_composition_positive"
    add_check_constraint :actor_label_evaluations, "source_height >= 0",
      name: "actor_label_evaluations_height_nonnegative"
    add_check_constraint :actor_label_evaluations,
      "status = 'certified' AND certification_scope = 'strict'",
      name: "actor_label_evaluations_strict_certification"
    add_check_constraint :actor_label_evaluations,
      "jsonb_typeof(rule_results) = 'object'",
      name: "actor_label_evaluations_results_object"

    add_reference :actor_labels, :actor_behavior_snapshot, foreign_key: true
    add_column :actor_labels, :rule_version, :string
    add_column :actor_labels, :certified_at, :datetime
  end
end
