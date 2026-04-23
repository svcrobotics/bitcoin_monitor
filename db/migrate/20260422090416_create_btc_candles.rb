# db/migrate/XXXXXXXXXXXXXX_create_btc_candles.rb
class CreateBtcCandles < ActiveRecord::Migration[8.0]
  def change
    create_table :btc_candles do |t|
      t.string   :market, null: false
      t.string   :timeframe, null: false
      t.datetime :open_time, null: false
      t.datetime :close_time, null: false

      t.decimal :open,  precision: 20, scale: 8, null: false
      t.decimal :high,  precision: 20, scale: 8, null: false
      t.decimal :low,   precision: 20, scale: 8, null: false
      t.decimal :close, precision: 20, scale: 8, null: false
      t.decimal :volume, precision: 24, scale: 8

      t.integer :trades_count
      t.string  :source, null: false

      t.timestamps
    end

    add_index :btc_candles, [:market, :timeframe, :open_time], unique: true
    add_index :btc_candles, :open_time
    add_index :btc_candles, [:market, :timeframe]
  end
end