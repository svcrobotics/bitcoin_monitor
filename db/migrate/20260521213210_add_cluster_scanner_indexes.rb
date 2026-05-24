class AddClusterScannerIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :tx_outputs,
              [:spent_block_height, :spent_txid],
              algorithm: :concurrently,
              name: "index_tx_outputs_on_spent_block_height_and_spent_txid"

    add_index :tx_outputs,
              [:spent_txid, :address],
              algorithm: :concurrently,
              name: "index_tx_outputs_on_spent_txid_and_address"

    add_index :address_links,
              [:txid, :link_type],
              algorithm: :concurrently,
              name: "index_address_links_on_txid_and_link_type"
  end
end