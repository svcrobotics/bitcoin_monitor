class ChangeBtcPriceDaysUniqueIndex < ActiveRecord::Migration[8.0]
  def change
    remove_index :btc_price_days, :day if index_exists?(:btc_price_days, :day)
    add_index :btc_price_days, [:day, :source], unique: true
  end
end