# frozen_string_literal: true

class AddSourceFirstIndexToClusterInputs <
  ActiveRecord::Migration[8.0]

  disable_ddl_transaction!

  def change
    add_index(
      :cluster_inputs,
      [
        :address,
        :spent_block_height
      ],
      where:
        "spent_txid IS NOT NULL",
      name:
        "idx_cluster_inputs_source_spends",
      algorithm:
        :concurrently,
      if_not_exists:
        true
    )
  end
end
