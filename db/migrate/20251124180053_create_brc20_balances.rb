class CreateBrc20Balances < ActiveRecord::Migration[8.0]
  def change
    create_table :brc20_balances do |t|
      t.references :brc20_token, null: false, foreign_key: true

      t.string  :tick,    null: false
      t.string  :address, null: false

      t.string  :balance,          null: false, default: "0"
      t.string  :minted,           null: false, default: "0"
      t.string  :transferred_in,   null: false, default: "0"
      t.string  :transferred_out,  null: false, default: "0"

      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false

      t.timestamps
    end

    add_index :brc20_balances, [:brc20_token_id, :address], unique: true
    add_index :brc20_balances, [:tick, :address]
  end
end
