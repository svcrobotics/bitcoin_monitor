# frozen_string_literal: true

class CreateExchangeCoreFlowDays < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_core_flow_days do |t|
      t.date :day, null: false

      t.decimal :inflow_btc, precision: 18, scale: 8, null: false, default: 0
      t.decimal :outflow_btc, precision: 18, scale: 8, null: false, default: 0
      t.decimal :netflow_btc, precision: 18, scale: 8, null: false, default: 0

      t.integer :events_count, null: false, default: 0
      t.string :source, null: false, default: "actor_graph_core"

      t.timestamps
    end

    add_index :exchange_core_flow_days, :day, unique: true
  end
end