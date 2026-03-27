class CreateExchangeFlowDays < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_flow_days do |t|
      t.date    :day, null: false

      t.decimal :inflow_btc,  precision: 20, scale: 8, null: false, default: 0
      t.decimal :outflow_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :netflow_btc, precision: 20, scale: 8, null: false, default: 0

      t.integer :inflow_utxo_count,  null: false, default: 0
      t.integer :outflow_utxo_count, null: false, default: 0

      t.datetime :computed_at

      t.timestamps
    end

    add_index :exchange_flow_days, :day, unique: true
  end
end