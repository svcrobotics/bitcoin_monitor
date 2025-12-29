class FixVaultAddressIndex < ActiveRecord::Migration[8.0]
  def up
    # Supprime l’index existant (qu’il soit unique ou non)
    remove_index :vaults, name: "index_vaults_on_address" if index_exists?(:vaults, :address, name: "index_vaults_on_address")

    # Recrée en NON-UNIQUE
    add_index :vaults, :address, name: "index_vaults_on_address"
  end

  def down
    remove_index :vaults, name: "index_vaults_on_address" if index_exists?(:vaults, :address, name: "index_vaults_on_address")
    add_index :vaults, :address, unique: true, name: "index_vaults_on_address"
  end
end
