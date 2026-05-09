class AddIndexOnSpentTxidToTxOutputs < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :tx_outputs,
              :spent_txid,
              name: "index_tx_outputs_on_spent_txid",
              algorithm: :concurrently
  end
end