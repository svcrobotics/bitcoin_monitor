class AddUniqueIndexToClusterProfiles < ActiveRecord::Migration[8.0]
  def change
    remove_index :cluster_profiles, :cluster_id

    add_index :cluster_profiles, :cluster_id, unique: true
  end
end