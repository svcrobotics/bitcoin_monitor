class AddWatchWalletNameToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :watch_wallet_name, :string
  end
end
