# frozen_string_literal: true

class AddClusterScannerIndexesToClusterInputs < ActiveRecord::Migration[8.0]
  def change
    add_index :cluster_inputs, :spent_txid
    add_index :cluster_inputs, :spent_block_height
    add_index :cluster_inputs, [:spent_block_height, :spent_txid]
  end
end