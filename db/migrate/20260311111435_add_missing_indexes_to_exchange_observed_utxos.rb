class AddMissingIndexesToExchangeObservedUtxos < ActiveRecord::Migration[8.0]
  def change
    add_index :exchange_observed_utxos, :address unless index_exists?(:exchange_observed_utxos, :address)

    add_index :exchange_observed_utxos, :spent_by_txid unless index_exists?(:exchange_observed_utxos, :spent_by_txid)

    add_index :exchange_observed_utxos,
              [:address, :seen_day],
              name: "index_exchange_observed_utxos_on_address_and_seen_day" unless index_exists?(
                :exchange_observed_utxos,
                [:address, :seen_day],
                name: "index_exchange_observed_utxos_on_address_and_seen_day"
              )
  end
end