class AddUniqueIndexToActorProfileDeltas < ActiveRecord::Migration[8.0]
  def change
    add_index :actor_profile_deltas,
      [:cluster_id, :block_height, :received_btc_delta, :sent_btc_delta, :tx_count_delta],
      unique: true,
      name: "index_actor_profile_deltas_unique_batch",
      if_not_exists: true
  end
end