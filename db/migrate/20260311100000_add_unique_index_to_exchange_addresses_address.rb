class AddUniqueIndexToExchangeAddressesAddress < ActiveRecord::Migration[8.0]
  def change
    add_index :exchange_addresses, :address, unique: true, name: "index_exchange_addresses_on_address"
  end
end