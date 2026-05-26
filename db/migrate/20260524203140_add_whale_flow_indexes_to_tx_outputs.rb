class AddWhaleFlowIndexesToTxOutputs < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    unless index_exists?(:tx_outputs, [:address, :block_time], name: "index_tx_outputs_on_address_and_block_time")
      add_index :tx_outputs, [:address, :block_time],
        algorithm: :concurrently,
        name: "index_tx_outputs_on_address_and_block_time"
    end

    unless index_exists?(:tx_outputs, [:address, :spent_block_height], name: "index_tx_outputs_on_address_and_spent_block_height")
      add_index :tx_outputs, [:address, :spent_block_height],
        algorithm: :concurrently,
        name: "index_tx_outputs_on_address_and_spent_block_height"
    end

    unless index_exists?(:addresses, [:cluster_id, :address], name: "index_addresses_on_cluster_id_and_address")
      add_index :addresses, [:cluster_id, :address],
        algorithm: :concurrently,
        name: "index_addresses_on_cluster_id_and_address"
    end
  end
end