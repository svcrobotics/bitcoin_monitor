# frozen_string_literal: true

class CreateEdges < ActiveRecord::Migration[8.0]
  def change
    create_table :edges do |t|
      t.string :txid, null: false

      t.string :address_a, null: false
      t.string :address_b, null: false

      t.integer :block_height
      t.string  :block_hash
      t.datetime :block_time

      t.timestamps
    end

    add_index :edges, [:address_a, :address_b]
    add_index :edges, :txid
    add_index :edges, :block_height
  end
end