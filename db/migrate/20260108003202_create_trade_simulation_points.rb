class CreateTradeSimulationPoints < ActiveRecord::Migration[8.0]
  def change
    create_table :trade_simulation_points do |t|
      t.references :trade_simulation, null: false, foreign_key: true
      t.date :day, null: false

      t.decimal :price_usd, precision: 20, scale: 8, null: false
      t.decimal :net_usd,   precision: 20, scale: 8, null: false
      t.decimal :pnl_usd,   precision: 20, scale: 8, null: false
      t.decimal :pnl_pct,   precision: 10, scale: 4, null: false

      t.timestamps
    end

    add_index :trade_simulation_points, [:trade_simulation_id, :day], unique: true
    add_index :trade_simulation_points, :day
  end
end
