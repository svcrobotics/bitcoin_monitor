class AddIncrementalFieldsToActorProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :actor_profiles, :last_computed_height, :integer
    add_column :actor_profiles, :dirty, :boolean, default: false, null: false
    add_column :actor_profiles, :priority, :string

    add_index :actor_profiles, :last_computed_height, if_not_exists: true
    add_index :actor_profiles, :dirty, if_not_exists: true
    add_index :actor_profiles, :priority, if_not_exists: true
  end
end