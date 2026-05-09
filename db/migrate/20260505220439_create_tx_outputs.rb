# frozen_string_literal: true

class CreateTxOutputs < ActiveRecord::Migration[8.0]
  def change
    create_table :tx_outputs do |t|
      t.string  :txid, null: false
      t.integer :vout, null: false

      t.string  :address
      t.decimal :amount_btc, precision: 20, scale: 8

      t.integer :block_height
      t.string  :block_hash
      t.datetime :block_time

      t.boolean :spent, null: false, default: false
      t.string  :spent_txid
      t.integer :spent_block_height

      t.timestamps
    end

    add_index :tx_outputs, [:txid, :vout], unique: true
    add_index :tx_outputs, :address
    add_index :tx_outputs, :spent
    add_index :tx_outputs, :block_height
  end
end