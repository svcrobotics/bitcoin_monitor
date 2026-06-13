class AddExchangeFlowIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :tx_outputs, [:block_height, :address],
              algorithm: :concurrently,
              if_not_exists: true

    add_index :tx_outputs, [:spent_block_height, :address],
              algorithm: :concurrently,
              if_not_exists: true

    add_index :tx_outputs, :spent_block_height,
              algorithm: :concurrently,
              if_not_exists: true
  end
end