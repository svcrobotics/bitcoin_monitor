class AddEurToBtcPriceDays < ActiveRecord::Migration[8.0]
  def change
    add_column :btc_price_days, :open_eur,  :decimal, precision: 20, scale: 8 unless column_exists?(:btc_price_days, :open_eur)
    add_column :btc_price_days, :high_eur,  :decimal, precision: 20, scale: 8 unless column_exists?(:btc_price_days, :high_eur)
    add_column :btc_price_days, :low_eur,   :decimal, precision: 20, scale: 8 unless column_exists?(:btc_price_days, :low_eur)
    add_column :btc_price_days, :close_eur, :decimal, precision: 20, scale: 8 unless column_exists?(:btc_price_days, :close_eur)
  end
end
