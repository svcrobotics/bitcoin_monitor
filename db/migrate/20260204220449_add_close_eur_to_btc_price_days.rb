class AddCloseEurToBtcPriceDays < ActiveRecord::Migration[8.0]
  def change
    add_column :btc_price_days, :close_eur, :decimal, precision: 20, scale: 8
  end
end
