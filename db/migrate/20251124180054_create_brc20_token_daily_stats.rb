class CreateBrc20TokenDailyStats < ActiveRecord::Migration[8.0]
  def change
    create_table :brc20_token_daily_stats do |t|
      t.references :brc20_token, null: false, foreign_key: true

      t.date    :day,             null: false

      t.integer :mint_count,      null: false, default: 0
      t.string  :mint_volume,     null: false, default: "0"

      t.integer :transfer_count,  null: false, default: 0
      t.string  :transfer_volume, null: false, default: "0"

      t.integer :active_addresses_count, null: false, default: 0

      t.timestamps
    end

    add_index :brc20_token_daily_stats, [:brc20_token_id, :day], unique: true
  end
end
