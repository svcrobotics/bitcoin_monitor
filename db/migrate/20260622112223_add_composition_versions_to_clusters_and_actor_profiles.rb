class AddCompositionVersionsToClustersAndActorProfiles < ActiveRecord::Migration[8.0]
  def up
    add_column(
    :clusters,
    :composition_version,
    :bigint,
    null: false,
    default: 0
    )


    add_column(
      :actor_profiles,
      :cluster_composition_version,
      :bigint,
      null: true
    )

    execute <<~SQL
      UPDATE clusters
      SET composition_version = 1
      WHERE EXISTS (
        SELECT 1
        FROM addresses
        WHERE addresses.cluster_id = clusters.id
      )
    SQL


  end

  def down
    remove_column(
    :actor_profiles,
    :cluster_composition_version
    )


    remove_column(
      :clusters,
      :composition_version
    )


  end
end
