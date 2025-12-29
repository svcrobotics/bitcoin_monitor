class AddRedeemScriptHexToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :redeem_script_hex, :text
  end
end
