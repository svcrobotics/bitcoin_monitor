# frozen_string_literal: true

class RemoveStandaloneSpentTxidIndexFromClusterInputs < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  INDEX_NAME = :index_cluster_inputs_on_spent_txid

  def up
    remove_index(
      :cluster_inputs,
      name: INDEX_NAME,
      algorithm: :concurrently,
      if_exists: true
    )
  end

  def down
    add_index(
      :cluster_inputs,
      :spent_txid,
      name: INDEX_NAME,
      algorithm: :concurrently,
      if_not_exists: true
    )
  end
end
