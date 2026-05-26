class RemoveUniqueIndexFromActorProfileDeltas < ActiveRecord::Migration[8.0]
  def change
    remove_index :actor_profile_deltas,
      name: "index_actor_profile_deltas_unique_batch",
      if_exists: true
  end
end