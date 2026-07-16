# frozen_string_literal: true

class AddCertificationEpochToActorProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :actor_profiles, :certification_epoch_height, :integer
    add_column :actor_profiles, :certification_scope, :string
    add_column :actor_profiles, :certified_at, :datetime

    add_index :actor_profiles,
      %i[certification_epoch_height dirty],
      name: "index_actor_profiles_on_epoch_and_dirty"
    add_index :actor_profiles,
      %i[certification_scope certification_epoch_height],
      name: "index_actor_profiles_on_scope_and_epoch"
    add_index :actor_profiles, :certified_at

    add_check_constraint :actor_profiles,
      "certification_epoch_height IS NULL OR certification_epoch_height > 0",
      name: "actor_profiles_positive_certification_epoch"
    add_check_constraint :actor_profiles,
      "certification_scope IS NULL OR certification_scope <> ''",
      name: "actor_profiles_certification_scope_present"
  end
end
