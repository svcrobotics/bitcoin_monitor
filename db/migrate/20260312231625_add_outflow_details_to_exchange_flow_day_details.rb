class AddOutflowDetailsToExchangeFlowDayDetails < ActiveRecord::Migration[8.0]
  def change
    add_column :exchange_flow_day_details, :withdrawal_count, :integer, null: false, default: 0

    add_column :exchange_flow_day_details, :avg_withdrawal_btc, :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :exchange_flow_day_details, :max_withdrawal_btc, :decimal, precision: 20, scale: 8, null: false, default: 0

    add_column :exchange_flow_day_details, :outflow_lt_1_btc, :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_1_10_btc, :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_10_100_btc, :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_100_500_btc, :decimal, precision: 20, scale: 8, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_gt_500_btc, :decimal, precision: 20, scale: 8, null: false, default: 0

    add_column :exchange_flow_day_details, :outflow_lt_1_count, :integer, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_1_10_count, :integer, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_10_100_count, :integer, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_100_500_count, :integer, null: false, default: 0
    add_column :exchange_flow_day_details, :outflow_gt_500_count, :integer, null: false, default: 0
  end
end