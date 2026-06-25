# frozen_string_literal: true

class AddStrictActorProfileIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    unless index_exists?(
      :actor_profiles,
      :cluster_id,
      unique: true,
      name: "index_actor_profiles_on_cluster_id_unique"
    )
      add_index(
        :actor_profiles,
        :cluster_id,
        unique: true,
        name: "index_actor_profiles_on_cluster_id_unique",
        algorithm: :concurrently
      )
    end
  end
end
