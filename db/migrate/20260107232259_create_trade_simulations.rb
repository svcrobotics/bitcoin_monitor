class CreateTradeSimulations < ActiveRecord::Migration[8.0]
  def change
    create_table :trade_simulations do |t|
      t.date :buy_day
      t.date :sell_day
      t.decimal :btc_amount, precision: 20, scale: 8, null: false

      t.decimal :buy_fee_pct, precision: 6, scale: 3, null: false, default: 0
      t.decimal :buy_fee_fixed_eur, precision: 12, scale: 2, null: false, default: 0

      t.decimal :sell_fee_pct, precision: 6, scale: 3, null: false, default: 0
      t.decimal :sell_fee_fixed_eur, precision: 12, scale: 2, null: false, default: 0

      t.decimal :slippage_pct, precision: 6, scale: 3, null: false, default: 0

      t.text :notes

      t.timestamps
    end
  end
end
