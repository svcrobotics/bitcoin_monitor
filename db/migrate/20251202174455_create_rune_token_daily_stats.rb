
class CreateRuneTokenDailyStats < ActiveRecord::Migration[8.0]
  def change
    create_table :rune_token_daily_stats do |t|
      t.references :rune_token, null: false, foreign_key: true
      t.date       :day,        null: false

      t.integer :tx_count,         null: false, default: 0
      t.integer :transfer_count,   null: false, default: 0
      t.integer :mint_count,       null: false, default: 0
      t.integer :burn_count,       null: false, default: 0

      t.decimal :volume, precision: 39, scale: 0, null: false, default: 0

      t.integer :unique_senders,         null: false, default: 0
      t.integer :unique_receivers,       null: false, default: 0
      t.integer :active_addresses_count, null: false, default: 0

      t.timestamps
    end

    add_index :rune_token_daily_stats, [:rune_token_id, :day], unique: true
    add_index :rune_token_daily_stats, :day
  end
end
