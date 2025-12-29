class ChangeBrc20BigNumbersToString < ActiveRecord::Migration[8.0]
  def up
    change_column :brc20_block_stats, :deploy_max, :string
    change_column :brc20_block_stats, :mint_volume, :string, default: "0", null: false
    change_column :brc20_block_stats, :transfer_volume, :string, default: "0", null: false
  end

  def down
    change_column :brc20_block_stats, :deploy_max, :bigint
    change_column :brc20_block_stats, :mint_volume, :bigint, default: 0, null: false
    change_column :brc20_block_stats, :transfer_volume, :bigint, default: 0, null: false
  end
end
