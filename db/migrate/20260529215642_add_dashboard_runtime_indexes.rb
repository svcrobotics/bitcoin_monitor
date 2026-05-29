class AddDashboardRuntimeIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :btc_candles,
      [:market, :timeframe, :open_time],
      order: { open_time: :desc },
      name: "index_btc_candles_dashboard_lookup",
      if_not_exists: true
  end
end