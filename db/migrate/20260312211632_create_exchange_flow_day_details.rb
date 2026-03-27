class CreateExchangeFlowDayDetails < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_flow_day_details do |t|
      t.date :day, null: false

      t.integer :deposit_count, null: false, default: 0

      t.decimal :avg_deposit_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :max_deposit_btc, precision: 20, scale: 8, null: false, default: 0

      t.decimal :inflow_lt_1_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :inflow_1_10_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :inflow_10_100_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :inflow_100_500_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :inflow_gt_500_btc, precision: 20, scale: 8, null: false, default: 0

      t.integer :inflow_lt_1_count, null: false, default: 0
      t.integer :inflow_1_10_count, null: false, default: 0
      t.integer :inflow_10_100_count, null: false, default: 0
      t.integer :inflow_100_500_count, null: false, default: 0
      t.integer :inflow_gt_500_count, null: false, default: 0

      t.datetime :computed_at

      t.timestamps
    end

    add_index :exchange_flow_day_details, :day, unique: true
  end
end