class AddTraitsToClusterProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :cluster_profiles, :traits, :text
  end
end
