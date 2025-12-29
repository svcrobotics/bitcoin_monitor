
class CreateRuneTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :rune_tokens do |t|
      # Identité Runes
      t.string  :rune_name,       null: false          # ex: "UNCOMMON•GOODS"
      t.string  :normalized_name, null: false          # ex: "uncommon_goods" ou version simplifiée
      t.integer :rune_id_block,   null: false          # partie bloc du rune id (block:tx)
      t.integer :rune_id_tx,      null: false          # partie index tx du rune id
      t.string  :symbol                               # éventuel alias court si tu en définis un

      # Termes / paramètres du token
      t.integer :divisibility,     null: false, default: 0   # nb de décimales
      t.decimal :cap_supply,       precision: 39, scale: 0   # supply max autorisée
      t.decimal :premine_amount,   precision: 39, scale: 0   # quantité pré-mintée
      t.decimal :minted_supply,    precision: 39, scale: 0, default: 0
      t.decimal :burned_supply,    precision: 39, scale: 0, default: 0

      t.boolean :minting_finished, null: false, default: false

      # Etching (création de la rune)
      t.string   :etching_txid
      t.integer  :etching_vout
      t.integer  :etching_block_height
      t.datetime :etching_block_time

      # Activité globale
      t.integer  :first_seen_block_height
      t.integer  :last_seen_block_height
      t.datetime :last_activity_at

      t.integer :events_count,    null: false, default: 0
      t.integer :transfers_count, null: false, default: 0
      t.integer :holders_count,   null: false, default: 0

      # Pour garder les termes bruts / options spécifiques
      t.jsonb :metadata

      t.timestamps
    end

    add_index :rune_tokens, [:rune_id_block, :rune_id_tx], unique: true
    add_index :rune_tokens, :normalized_name
    add_index :rune_tokens, :etching_txid, unique: true
  end
end
