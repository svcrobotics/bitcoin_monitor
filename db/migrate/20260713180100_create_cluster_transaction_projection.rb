# frozen_string_literal: true

class CreateClusterTransactionProjection < ActiveRecord::Migration[8.0]
  GENERATION_STATUSES =
    %w[pending building certified failed stale replaced].freeze

  BLOCK_STATUSES =
    %w[pending processing projected failed stale].freeze

  def change
    create_table :cluster_transaction_projection_generations do |t|
      t.bigint :cluster_id, null: false
      t.bigint :composition_version, null: false
      t.integer :checkpoint_height, null: false
      t.string :checkpoint_hash, null: false
      t.string :status, null: false, default: "pending"

      t.bigint :inflow_count, null: false, default: 0
      t.bigint :outflow_count, null: false, default: 0
      t.bigint :tx_count, null: false, default: 0
      t.bigint :facts_count, null: false, default: 0

      t.datetime :started_at
      t.datetime :certified_at
      t.datetime :failed_at
      t.datetime :stale_at
      t.string :stale_reason
      t.text :last_error

      t.timestamps
    end

    add_index(
      :cluster_transaction_projection_generations,
      [:cluster_id, :composition_version],
      name: "idx_ctp_generations_cluster_revision"
    )

    add_index(
      :cluster_transaction_projection_generations,
      [:cluster_id, :checkpoint_height],
      name: "idx_ctp_generations_cluster_checkpoint"
    )

    add_index(
      :cluster_transaction_projection_generations,
      [:status, :checkpoint_height],
      name: "idx_ctp_generations_status_checkpoint"
    )

    add_index(
      :cluster_transaction_projection_generations,
      :cluster_id,
      unique: true,
      where: "status = 'certified'",
      name: "idx_ctp_generations_one_certified_cluster"
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "composition_version >= 1",
      name: "ctp_generations_revision_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "checkpoint_height >= 0",
      name: "ctp_generations_checkpoint_height_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "BTRIM(checkpoint_hash) <> ''",
      name: "ctp_generations_checkpoint_hash_present"
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "status IN (#{quoted_statuses(GENERATION_STATUSES)})",
      name: "ctp_generations_status_check"
    )

    %w[inflow_count outflow_count tx_count facts_count].each do |column|
      add_check_constraint(
        :cluster_transaction_projection_generations,
        "#{column} >= 0",
        name: "ctp_generations_#{column}_check"
      )
    end

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "status <> 'certified' OR certified_at IS NOT NULL",
      name: "ctp_generations_certified_at_check"
    )

    create_table :cluster_transaction_facts, id: false do |t|
      t.references(
        :projection_generation,
        null: false,
        foreign_key: {
          to_table: :cluster_transaction_projection_generations,
          on_delete: :cascade
        },
        index: false
      )

      t.binary :txid, null: false
      t.integer :received_height
      t.integer :spent_height

      t.timestamps
    end

    add_index(
      :cluster_transaction_facts,
      [:projection_generation_id, :txid],
      unique: true,
      name: "idx_ctp_facts_generation_txid"
    )

    add_check_constraint(
      :cluster_transaction_facts,
      "octet_length(txid) = 32",
      name: "ctp_facts_txid_length_check"
    )

    add_check_constraint(
      :cluster_transaction_facts,
      "received_height IS NOT NULL OR spent_height IS NOT NULL",
      name: "ctp_facts_presence_check"
    )

    add_check_constraint(
      :cluster_transaction_facts,
      "received_height IS NULL OR received_height >= 0",
      name: "ctp_facts_received_height_check"
    )

    add_check_constraint(
      :cluster_transaction_facts,
      "spent_height IS NULL OR spent_height >= 0",
      name: "ctp_facts_spent_height_check"
    )

    create_table :cluster_transaction_projection_blocks do |t|
      t.integer :block_height, null: false
      t.string :block_hash, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.text :last_error

      t.timestamps
    end

    add_index(
      :cluster_transaction_projection_blocks,
      :block_height,
      unique: true,
      name: "idx_ctp_blocks_height"
    )

    add_index(
      :cluster_transaction_projection_blocks,
      [:status, :block_height],
      name: "idx_ctp_blocks_status_height"
    )

    add_check_constraint(
      :cluster_transaction_projection_blocks,
      "block_height >= 0",
      name: "ctp_blocks_height_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_blocks,
      "BTRIM(block_hash) <> ''",
      name: "ctp_blocks_hash_present"
    )

    add_check_constraint(
      :cluster_transaction_projection_blocks,
      "status IN (#{quoted_statuses(BLOCK_STATUSES)})",
      name: "ctp_blocks_status_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_blocks,
      "status <> 'projected' OR completed_at IS NOT NULL",
      name: "ctp_blocks_projected_at_check"
    )
  end

  private

  def quoted_statuses(statuses)
    statuses.map { |status| quote(status) }.join(", ")
  end
end
