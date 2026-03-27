class AddSpentBlockhashToExchangeObservedUtxos < ActiveRecord::Migration[8.0]
  def change
    add_column :exchange_observed_utxos, :spent_blockhash, :string
    add_column :exchange_observed_utxos, :spent_blockheight, :integer
  end
end
