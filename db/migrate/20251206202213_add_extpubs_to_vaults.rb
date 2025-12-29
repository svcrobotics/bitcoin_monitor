class AddExtpubsToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :xpub_a, :string
    add_column :vaults, :xpub_b, :string
  end
end
