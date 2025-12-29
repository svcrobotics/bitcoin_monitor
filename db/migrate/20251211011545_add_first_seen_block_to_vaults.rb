class AddFirstSeenBlockToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :first_seen_block, :integer
    add_index  :vaults, :first_seen_block
  end
end
