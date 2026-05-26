class CreateWhaleCoreFlowDays < ActiveRecord::Migration[8.0]
  def change
    create_table :whale_core_flow_days do |t|
      t.date :day
      t.decimal :inflow_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :outflow_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :netflow_btc, precision: 20, scale: 8, null: false, default: 0
      t.integer :events_count, null: false, default: 0
      t.string :source

      t.timestamps
    end

    add_index :whale_core_flow_events, [:txid, :address, :direction], unique: true
    add_index :whale_core_flow_events, :block_height
    add_index :whale_core_flow_events, :cluster_id
    add_index :whale_core_flow_events, :event_time

    add_index :whale_core_flow_days, :day, unique: true
  end
end
