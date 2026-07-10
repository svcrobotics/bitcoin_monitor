# frozen_string_literal: true

class CreateAddressUtxoProjection < ActiveRecord::Migration[8.0]
  def change
    create_table :address_utxo_stats do |t|
      t.string :address, null: false

      t.bigint :total_received_sats,
        null: false,
        default: 0

      t.bigint :current_balance_sats,
        null: false,
        default: 0

      t.bigint :live_utxo_count,
        null: false,
        default: 0

      t.bigint :received_output_count,
        null: false,
        default: 0

      t.integer :first_received_height
      t.integer :last_received_height

      t.integer :last_changed_height,
        null: false

      t.string :projection_version,
        null: false

      t.jsonb :metadata,
        null: false,
        default: {}

      t.timestamps
    end

    add_index :address_utxo_stats,
      :address,
      unique: true

    add_index :address_utxo_stats,
      :last_changed_height

    add_check_constraint :address_utxo_stats,
      "BTRIM(address) <> ''",
      name: "address_utxo_stats_address_present"

    add_check_constraint :address_utxo_stats,
      "total_received_sats >= 0",
      name: "address_utxo_stats_total_received_sats_check"

    add_check_constraint :address_utxo_stats,
      "current_balance_sats >= 0",
      name: "address_utxo_stats_current_balance_sats_check"

    add_check_constraint :address_utxo_stats,
      "live_utxo_count >= 0",
      name: "address_utxo_stats_live_utxo_count_check"

    add_check_constraint :address_utxo_stats,
      "received_output_count >= 0",
      name: "address_utxo_stats_received_output_count_check"

    add_check_constraint :address_utxo_stats,
      "current_balance_sats <= total_received_sats",
      name: "address_utxo_stats_balance_lte_received_check"

    add_check_constraint :address_utxo_stats,
      "last_changed_height >= 0",
      name: "address_utxo_stats_last_changed_height_check"

    add_check_constraint :address_utxo_stats,
      "first_received_height IS NULL OR first_received_height >= 0",
      name: "address_utxo_stats_first_received_height_check"

    add_check_constraint :address_utxo_stats,
      "last_received_height IS NULL OR last_received_height >= 0",
      name: "address_utxo_stats_last_received_height_check"

    add_check_constraint :address_utxo_stats,
      "first_received_height IS NULL OR last_received_height IS NULL OR first_received_height <= last_received_height",
      name: "address_utxo_stats_received_height_order_check"

    add_check_constraint :address_utxo_stats,
      "BTRIM(projection_version) <> ''",
      name: "address_utxo_stats_projection_version_present"

    create_table :address_utxo_projection_blocks do |t|
      t.integer :height, null: false
      t.string :block_hash, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0

      t.bigint :received_output_count,
        null: false,
        default: 0

      t.bigint :spent_output_count,
        null: false,
        default: 0

      t.integer :received_address_count,
        null: false,
        default: 0

      t.integer :spent_address_count,
        null: false,
        default: 0

      t.bigint :total_received_sats,
        null: false,
        default: 0

      t.bigint :total_spent_sats,
        null: false,
        default: 0

      t.datetime :processing_started_at
      t.datetime :completed_at
      t.text :error_message

      t.jsonb :metadata,
        null: false,
        default: {}

      t.timestamps
    end

    add_index :address_utxo_projection_blocks,
      :height,
      unique: true

    add_index :address_utxo_projection_blocks,
      [:status, :height]

    add_check_constraint :address_utxo_projection_blocks,
      "height >= 0",
      name: "address_utxo_projection_blocks_height_check"

    add_check_constraint :address_utxo_projection_blocks,
      "BTRIM(block_hash) <> ''",
      name: "address_utxo_projection_blocks_block_hash_present"

    add_check_constraint :address_utxo_projection_blocks,
      "status IN ('pending', 'processing', 'completed', 'failed', 'stale')",
      name: "address_utxo_projection_blocks_status_check"

    add_check_constraint :address_utxo_projection_blocks,
      "attempts >= 0",
      name: "address_utxo_projection_blocks_attempts_check"

    add_check_constraint :address_utxo_projection_blocks,
      "received_output_count >= 0",
      name: "address_utxo_projection_blocks_received_output_count_check"

    add_check_constraint :address_utxo_projection_blocks,
      "spent_output_count >= 0",
      name: "address_utxo_projection_blocks_spent_output_count_check"

    add_check_constraint :address_utxo_projection_blocks,
      "received_address_count >= 0",
      name: "address_utxo_projection_blocks_received_address_count_check"

    add_check_constraint :address_utxo_projection_blocks,
      "spent_address_count >= 0",
      name: "address_utxo_projection_blocks_spent_address_count_check"

    add_check_constraint :address_utxo_projection_blocks,
      "total_received_sats >= 0",
      name: "address_utxo_projection_blocks_total_received_sats_check"

    add_check_constraint :address_utxo_projection_blocks,
      "total_spent_sats >= 0",
      name: "address_utxo_projection_blocks_total_spent_sats_check"

    add_check_constraint :address_utxo_projection_blocks,
      "status <> 'completed' OR completed_at IS NOT NULL",
      name: "address_utxo_projection_blocks_completed_at_check"
  end
end
