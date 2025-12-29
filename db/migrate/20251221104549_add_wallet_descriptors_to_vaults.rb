# db/migrate/XXXXXXXXXX_add_wallet_descriptors_to_vaults.rb
class AddWalletDescriptorsToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :receive_descriptor, :text
    add_column :vaults, :change_descriptor,  :text
    add_column :vaults, :scan_range, :integer, default: 200, null: false

    # address devient optionnelle et NON unique (si tu veux la garder comme "sample")
    if index_exists?(:vaults, :address, unique: true)
      remove_index :vaults, :address
      add_index :vaults, :address
    end
  end
end
