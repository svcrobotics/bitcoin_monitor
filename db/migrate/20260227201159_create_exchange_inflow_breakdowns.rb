# frozen_string_literal: true

class CreateExchangeInflowBreakdowns < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_inflow_breakdowns do |t|
      t.date    :day,    null: false
      t.string  :scope,  null: false, default: "inflow"  # "inflow" or "custody"
      t.integer :min_occ, null: false, default: 8         # quelle config a produit ce breakdown

      # Buckets BTC (les 4 que tu affiches)
      t.decimal :lt10_btc,     precision: 20, scale: 8, null: false, default: 0
      t.decimal :b10_99_btc,   precision: 20, scale: 8, null: false, default: 0
      t.decimal :b100_499_btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :b500p_btc,    precision: 20, scale: 8, null: false, default: 0

      # Totaux / counts utiles UI + debug
      t.decimal :total_btc, precision: 20, scale: 8, null: false, default: 0
      t.integer :utxos_count, null: false, default: 0
      t.integer :addresses_count, null: false, default: 0

      # Concentration (pro)
      t.decimal :top1_btc,  precision: 20, scale: 8
      t.decimal :top10_btc, precision: 20, scale: 8
      t.decimal :top1_pct,  precision: 8,  scale: 4
      t.decimal :top10_pct, precision: 8,  scale: 4

      # Métadonnées: top addresses (facultatif), coverage, etc.
      t.jsonb :meta, null: false, default: {}

      t.timestamps
    end

    add_index :exchange_inflow_breakdowns, [:day, :scope, :min_occ], unique: true, name: "idx_inflow_breakdowns_day_scope_occ"
    add_index :exchange_inflow_breakdowns, :day
  end
end