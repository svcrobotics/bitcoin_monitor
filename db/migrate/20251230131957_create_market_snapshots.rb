class CreateMarketSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :market_snapshots do |t|
      t.datetime :computed_at, null: false

      t.decimal :price_now_usd,        precision: 20, scale: 8
      t.decimal :ma200_usd,             precision: 20, scale: 8
      t.decimal :price_vs_ma200_pct,    precision: 10, scale: 4

      t.decimal :ath_usd,               precision: 20, scale: 8
      t.decimal :drawdown_pct,          precision: 10, scale: 4
      t.decimal :amplitude_30d_pct,     precision: 10, scale: 4

      t.string  :market_bias, null: false
      t.string  :cycle_zone,  null: false
      t.string  :risk_level,  null: false

      t.jsonb   :reasons, null: false, default: []
      t.string  :status,  null: false, default: "ok"
      t.text    :error_message

      t.timestamps
    end

    add_index :market_snapshots, :computed_at
    add_index :market_snapshots, :status
  end
end
