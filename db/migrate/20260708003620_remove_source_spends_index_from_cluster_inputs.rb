# frozen_string_literal: true

class RemoveSourceSpendsIndexFromClusterInputs < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  INDEX_NAME = :idx_cluster_inputs_source_spends

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
      %i[address spent_block_height],
      name: INDEX_NAME,
      where: "spent_txid IS NOT NULL",
      algorithm: :concurrently,
      if_not_exists: true
    )
  end
end