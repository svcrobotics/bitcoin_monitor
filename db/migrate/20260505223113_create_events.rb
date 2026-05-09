# frozen_string_literal: true

class CreateEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :events do |t|
      t.string  :event_type, null: false

      # contexte blockchain
      t.string  :txid
      t.integer :block_height
      t.string  :block_hash
      t.datetime :block_time

      # payload générique
      t.jsonb :data, null: false, default: {}

      t.timestamps
    end

    # -----------------------------
    # INDEXES
    # -----------------------------
    add_index :events, :event_type
    add_index :events, :txid
    add_index :events, :block_height
    add_index :events, :block_hash

    # pour requêtes JSON (important)
    add_index :events, :data, using: :gin
  end
end