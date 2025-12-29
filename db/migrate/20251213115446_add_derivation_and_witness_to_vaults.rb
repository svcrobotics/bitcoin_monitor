class AddDerivationAndWitnessToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :derivation_path,  :string
    add_column :vaults, :derivation_index, :integer

    add_column :vaults, :pubkey_a_child, :string
    add_column :vaults, :pubkey_b_child, :string

    add_column :vaults, :witness_script, :text

    add_index :vaults, [:derivation_path, :derivation_index],
              name: "index_vaults_on_derivation"
  end
end
