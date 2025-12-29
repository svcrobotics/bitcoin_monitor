class RemoveDuplicateUniqueIndexFromVaultAddresses < ActiveRecord::Migration[8.0]
  def change
    remove_index :vault_addresses, name: "index_vault_addresses_on_vault_id_and_kind_and_index"
  end
end
