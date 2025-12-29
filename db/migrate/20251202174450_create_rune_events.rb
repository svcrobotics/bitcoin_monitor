
class CreateRuneEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :rune_events do |t|
      t.references :rune_token, foreign_key: true, null: true

      # Copie du nom façon tick pour debug rapide (optionnel mais pratique)
      t.string :rune_name

      # Type d’événement : "etch", "mint", "transfer", "burn", "unknown"
      t.string :op, null: false

      # Ancrage blockchain
      t.string   :txid,         null: false
      t.integer  :vout
      t.integer  :vin
      t.integer  :block_height
      t.datetime :block_time

      # Quantité de Runes dans cet event (en "units" entiers, avant divisibilité)
      t.decimal :amount, precision: 39, scale: 0

      # Pour simplifier, on stocke les adresses humaines, même si Runes est UTXO-centric
      t.string :from_address
      t.string :to_address

      t.boolean :is_valid, null: false, default: true

      # Payload brut de la runestone / données d’analyse
      t.jsonb :raw_payload

      t.timestamps
    end

    add_index :rune_events, :txid
    add_index :rune_events, :block_height
    add_index :rune_events, :op
    add_index :rune_events, [:rune_token_id, :block_height]
  end
end
