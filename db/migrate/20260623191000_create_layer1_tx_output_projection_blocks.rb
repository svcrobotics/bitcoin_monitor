# frozen_string_literal: true

class CreateLayer1TxOutputProjectionBlocks < ActiveRecord::Migration[8.0]
  def change
    create_table :layer1_tx_output_projection_blocks do |t|
      t.bigint :height, null: false
      t.string :block_hash, null: false
      t.string :status, null: false, default: "pending"

      t.integer :expected_outputs_count, null: false, default: 0
      t.decimal :expected_outputs_value_btc,
        precision: 24,
        scale: 8,
        null: false,
        default: 0

      t.integer :projected_outputs_count, null: false, default: 0
      t.decimal :projected_outputs_value_btc,
        precision: 24,
        scale: 8,
        null: false,
        default: 0

      t.integer :rows_inserted, null: false, default: 0
      t.integer :rows_skipped, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.integer :duration_ms

      t.datetime :started_at
      t.datetime :last_attempt_at
      t.datetime :completed_at
      t.text :last_error
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :layer1_tx_output_projection_blocks,
      :height,
      unique: true

    add_index :layer1_tx_output_projection_blocks,
      [:status, :height],
      name: "idx_layer1_tx_output_projection_status_height"

    add_index :layer1_tx_output_projection_blocks,
      :completed_at
  end
end
