class CreateBrc20BlockStats < ActiveRecord::Migration[8.0]
  def change
    create_table :brc20_block_stats do |t|
      t.integer :block_height, null: false
      t.string  :block_hash,   null: false
      t.string  :tick,         null: false

      t.integer :deploy_count,    null: false, default: 0
      t.bigint  :deploy_max

      t.integer :mint_count,      null: false, default: 0
      t.bigint  :mint_volume,     null: false, default: 0

      t.integer :transfer_count,  null: false, default: 0
      t.bigint  :transfer_volume, null: false, default: 0

      t.timestamps
    end

    add_index :brc20_block_stats, :block_height
    add_index :brc20_block_stats, :tick
    add_index :brc20_block_stats, [:block_height, :tick], unique: true
  end
end
