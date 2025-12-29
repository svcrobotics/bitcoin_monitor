class AddCsvBlocksToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :csv_blocks, :integer
  end
end
