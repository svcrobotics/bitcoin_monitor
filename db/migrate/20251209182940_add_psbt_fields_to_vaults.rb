class AddPsbtFieldsToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :psbt_last_generated, :text
    add_column :vaults, :psbt_signed_by_a, :text
    add_column :vaults, :psbt_signed_by_b, :text
  end
end
