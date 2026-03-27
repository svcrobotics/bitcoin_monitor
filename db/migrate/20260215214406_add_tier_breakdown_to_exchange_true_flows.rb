class AddTierBreakdownToExchangeTrueFlows < ActiveRecord::Migration[8.0]
  def change
    add_column :exchange_true_flows, :inflow_b_btc, :numeric
    add_column :exchange_true_flows, :inflow_a_btc, :numeric
    add_column :exchange_true_flows, :inflow_s_btc, :numeric

    add_column :exchange_true_flows, :avg30_b, :numeric
    add_column :exchange_true_flows, :avg30_a, :numeric
    add_column :exchange_true_flows, :avg30_s, :numeric

    add_column :exchange_true_flows, :ratio30_b, :numeric
    add_column :exchange_true_flows, :ratio30_a, :numeric
    add_column :exchange_true_flows, :ratio30_s, :numeric
  end
end
