class CreateBrc20Events < ActiveRecord::Migration[8.0]
  def change
    create_table :brc20_events do |t|
      t.references :brc20_token, foreign_key: true

      t.string  :tick,           null: false        # redondant mais pratique pour les requêtes
      t.string  :txid,           null: false
      t.string  :inscription_id, null: false

      t.integer :block_height,   null: false
      t.string  :block_hash,     null: false
      t.datetime :block_time,    null: false

      t.string  :op,             null: false        # "deploy" / "mint" / "transfer"
      t.string  :amount,         null: false, default: "0"

      t.string  :from_address
      t.string  :to_address

      t.json    :payload                          # JSON complet décodé de l’inscription

      t.boolean :valid,         null: false, default: true
      t.string  :invalid_reason

      t.timestamps
    end

    add_index :brc20_events, :txid
    add_index :brc20_events, :inscription_id, unique: true
    add_index :brc20_events, [:tick, :block_height]
    add_index :brc20_events, [:brc20_token_id, :block_height]
  end
end
