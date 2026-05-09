# frozen_string_literal: true

class AddUniqueIndexToEdges < ActiveRecord::Migration[8.0]
  def change
    add_index :edges,
      [:txid, :address_a, :address_b],
      unique: true,
      name: "index_edges_unique_triplet"
  end
end