class CreateBrc20Tokens < ActiveRecord::Migration[8.0]
  def change
    create_table :brc20_tokens do |t|
      t.string  :tick, null: false             # ex: "ordi"
      t.string  :symbol                        # alias si besoin (facultatif)

      t.string  :deploy_inscription_id, null: false
      t.string  :deploy_txid,          null: false
      t.integer :deploy_block_height,  null: false
      t.string  :deploy_block_hash,    null: false
      t.datetime :deploy_block_time,   null: false

      t.string  :max_supply,    null: false      # string pour gérer les très gros nombres
      t.string  :mint_limit                    # "lim" dans le JSON
      t.integer :decimals,     null: false, default: 18

      # Stats cumulées
      t.string  :total_minted,     null: false, default: "0"
      t.string  :total_transferred, null: false, default: "0"
      t.integer :holders_count,    null: false, default: 0
      t.integer :events_count,     null: false, default: 0

      t.timestamps
    end

    add_index :brc20_tokens, :tick, unique: true
  end
end
