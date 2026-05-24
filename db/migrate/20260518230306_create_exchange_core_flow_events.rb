# frozen_string_literal: true

class CreateExchangeCoreFlowEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_core_flow_events do |t|
      t.integer :block_height, null: false
      t.string :block_hash
      t.string :txid, null: false

      t.string :address, null: false
      t.bigint :cluster_id

      t.string :direction, null: false # inflow / outflow
      t.decimal :amount_btc, precision: 18, scale: 8, null: false, default: 0

      t.datetime :event_time
      t.string :source, null: false, default: "actor_graph"

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :exchange_core_flow_events, :block_height
    add_index :exchange_core_flow_events, :txid
    add_index :exchange_core_flow_events, :address
    add_index :exchange_core_flow_events, :cluster_id
    add_index :exchange_core_flow_events, :direction
    add_index :exchange_core_flow_events, :event_time
    add_index :exchange_core_flow_events, [:txid, :address, :direction], unique: true
  end
end