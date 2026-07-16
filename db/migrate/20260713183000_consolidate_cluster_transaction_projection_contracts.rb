# frozen_string_literal: true

class ConsolidateClusterTransactionProjectionContracts < ActiveRecord::Migration[8.0]
  def change
    remove_index(
      :cluster_transaction_projection_generations,
      name: "idx_ctp_generations_one_certified_revision",
      if_exists: true
    )

    add_index(
      :cluster_transaction_projection_generations,
      :cluster_id,
      unique: true,
      where: "status = 'certified'",
      name: "idx_ctp_generations_one_certified_cluster"
    )

    remove_check_constraint(
      :cluster_transaction_projection_blocks,
      name: "ctp_blocks_status_check",
      if_exists: true
    )

    add_check_constraint(
      :cluster_transaction_projection_blocks,
      "status IN ('pending', 'processing', 'projected', 'failed', 'stale')",
      name: "ctp_blocks_status_check"
    )

    remove_check_constraint(
      :cluster_transaction_projection_blocks,
      name: "ctp_blocks_completed_at_check",
      if_exists: true
    )

    add_check_constraint(
      :cluster_transaction_projection_blocks,
      "status <> 'projected' OR completed_at IS NOT NULL",
      name: "ctp_blocks_projected_at_check"
    )

    create_table :cluster_composition_revision_repair_checkpoints do |t|
      t.string :status, null: false, default: "pending"
      t.bigint :last_cluster_id, null: false, default: 0
      t.bigint :scanned_count, null: false, default: 0
      t.bigint :updated_count, null: false, default: 0
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.text :last_error

      t.timestamps
    end

    add_check_constraint(
      :cluster_composition_revision_repair_checkpoints,
      "status IN ('pending', 'processing', 'completed', 'failed')",
      name: "cluster_revision_repair_status_check"
    )

    add_check_constraint(
      :cluster_composition_revision_repair_checkpoints,
      "last_cluster_id >= 0",
      name: "cluster_revision_repair_last_cluster_id_check"
    )

    add_check_constraint(
      :cluster_composition_revision_repair_checkpoints,
      "scanned_count >= 0",
      name: "cluster_revision_repair_scanned_count_check"
    )

    add_check_constraint(
      :cluster_composition_revision_repair_checkpoints,
      "updated_count >= 0",
      name: "cluster_revision_repair_updated_count_check"
    )
  end
end
