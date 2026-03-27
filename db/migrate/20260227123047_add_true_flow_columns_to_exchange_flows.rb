# frozen_string_literal: true

class AddTrueFlowColumnsToExchangeFlows < ActiveRecord::Migration[8.0]
  def change
    # true_inflow_btc existe déjà chez toi => on ne le touche pas
    add_column :exchange_flows, :true_outflow_btc, :decimal, precision: 20, scale: 8 unless column_exists?(:exchange_flows, :true_outflow_btc)
    add_column :exchange_flows, :true_net_btc,     :decimal, precision: 20, scale: 8 unless column_exists?(:exchange_flows, :true_net_btc)

    add_index :exchange_flows, :true_outflow_btc unless index_exists?(:exchange_flows, :true_outflow_btc)
  end
end