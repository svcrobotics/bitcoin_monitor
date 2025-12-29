class AddPsbtDebugToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :psbt_last_debug, :text
  end
end
