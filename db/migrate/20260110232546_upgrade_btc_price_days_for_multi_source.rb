class UpgradeBtcPriceDaysForMultiSource < ActiveRecord::Migration[8.0]
  def change
    add_column :btc_price_days, :volume_btc,  :decimal, precision: 20, scale: 8
    add_column :btc_price_days, :sources_json, :jsonb, default: {}, null: false
    add_column :btc_price_days, :computed_at, :datetime

    add_index :btc_price_days, :computed_at
  end
end
