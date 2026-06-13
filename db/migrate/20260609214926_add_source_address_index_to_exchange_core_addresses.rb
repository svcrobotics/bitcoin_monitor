class AddSourceAddressIndexToExchangeCoreAddresses < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :exchange_core_addresses,
              [:source, :address],
              algorithm: :concurrently,
              if_not_exists: true
  end
end