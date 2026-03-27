# frozen_string_literal: true

class CreateExchangeObservedUtxos < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_observed_utxos do |t|
      # --- Identification de l'UTXO ---
      t.string  :txid, null: false
      t.integer :vout, null: false

      # --- Métadonnées ---
      t.string  :address
      t.decimal :value_btc, precision: 20, scale: 8, null: false
      t.date    :seen_day, null: false
      t.string  :source, default: "trueflow", null: false

      # --- Dépense (outflow observé) ---
      t.datetime :spent_at
      t.date     :spent_day
      t.string   :spent_by_txid

      t.timestamps
    end

    # Un UTXO est unique par (txid, vout)
    add_index :exchange_observed_utxos, [:txid, :vout], unique: true

    # Index utiles pour requêtes et debug
    add_index :exchange_observed_utxos, :seen_day
    add_index :exchange_observed_utxos, :spent_day
    add_index :exchange_observed_utxos, :spent_at
  end
end
