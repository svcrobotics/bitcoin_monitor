class CreateBtcPriceDays < ActiveRecord::Migration[8.0]
  def change
    create_table :btc_price_days do |t|
      t.date :day, null: false

      t.decimal :open_usd,  precision: 20, scale: 8
      t.decimal :high_usd,  precision: 20, scale: 8
      t.decimal :low_usd,   precision: 20, scale: 8
      t.decimal :close_usd, precision: 20, scale: 8, null: false

      t.string :source, null: false, default: "coingecko"

      t.timestamps
    end

    add_index :btc_price_days, :day, unique: true
  end
end
