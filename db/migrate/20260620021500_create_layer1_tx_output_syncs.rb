# frozen_string_literal: true

class CreateLayer1TxOutputSyncs < ActiveRecord::Migration[8.0]
  def change
    create_table :layer1_tx_output_syncs do |t|
      t.bigint :height, null: false
      t.string :block_hash, null: false
      t.string :status, null: false, default: "pending"
      t.integer :inputs_count, null: false, default: 0
      t.integer :matching_tx_outputs_count, null: false, default: 0
      t.integer :rows_updated, null: false, default: 0
      t.integer :remaining_rows
      t.integer :attempts, null: false, default: 0
      t.integer :duration_ms
      t.datetime :started_at
      t.datetime :last_attempt_at
      t.datetime :completed_at
      t.text :last_error
      t.timestamps
    end

    add_index :layer1_tx_output_syncs, :height, unique: true
    add_index :layer1_tx_output_syncs, [:status, :height]
    add_index :layer1_tx_output_syncs, :completed_at
  end
end
