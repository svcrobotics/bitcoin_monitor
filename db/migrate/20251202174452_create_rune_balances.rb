
class CreateRuneBalances < ActiveRecord::Migration[8.0]
  def change
    create_table :rune_balances do |t|
      t.references :rune_token, null: false, foreign_key: true
      t.string     :address,    null: false

      t.decimal :balance, precision: 39, scale: 0, null: false, default: 0

      t.integer  :first_seen_block_height
      t.integer  :last_seen_block_height
      t.datetime :last_updated_at

      t.timestamps
    end

    add_index :rune_balances, [:rune_token_id, :address], unique: true
    add_index :rune_balances, :address
  end
end

