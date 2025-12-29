class AddUniqueIndexToVaultAddresses < ActiveRecord::Migration[8.0]
  def change
    add_index :vault_addresses,
              [:vault_id, :kind, :index],
              unique: true,
              name: "idx_vault_addresses_unique"
  end
end
