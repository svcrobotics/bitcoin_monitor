class AddAdvancedOutflowToExchangeTrueFlows < ActiveRecord::Migration[8.0]
  def change
    add_column :exchange_true_flows, :outflow_ext_btc, :numeric
    add_column :exchange_true_flows, :outflow_int_btc, :numeric
    add_column :exchange_true_flows, :outflow_gross_btc, :numeric
    add_column :exchange_true_flows, :outflow_confidence, :numeric
    add_column :exchange_true_flows, :outflow_kind, :string

    add_index :exchange_true_flows, :outflow_kind
  end
end
