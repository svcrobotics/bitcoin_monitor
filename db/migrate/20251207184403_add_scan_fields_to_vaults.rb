class AddScanFieldsToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :balance_sats, :bigint
    add_column :vaults, :utxos_count, :integer
    add_column :vaults, :utxos_unconfirmed_count, :integer
    add_column :vaults, :last_scanned_at, :datetime
    add_column :vaults, :last_scan_status, :string
    add_column :vaults, :last_scan_error, :text
  end
end
