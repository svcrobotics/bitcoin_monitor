class AddExtpubsAndAddressesToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :address_a, :string
    add_column :vaults, :address_b, :string
  end
end
