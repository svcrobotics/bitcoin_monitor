class AddLedgerFingerprintsToVaults < ActiveRecord::Migration[8.0]
  def change
    add_column :vaults, :ledger_a_fp, :string
    add_column :vaults, :ledger_b_fp, :string
  end
end
