class GeneralizeActorBehaviorHeavySnapshots < ActiveRecord::Migration[8.0]
  COMPOSITE_INDEX_NAME =
    "idx_actor_behavior_heavy_snapshots_cluster_analysis".freeze

  def up
    change_column_null(
      :actor_behavior_heavy_snapshots,
      :downstream_cluster_id,
      true
    )

    if index_exists?(
      :actor_behavior_heavy_snapshots,
      :cluster_id,
      unique: true
    )
      remove_index(
        :actor_behavior_heavy_snapshots,
        column: :cluster_id
      )
    end

    unless index_exists?(
      :actor_behavior_heavy_snapshots,
      %i[cluster_id analysis_kind],
      unique: true,
      name: COMPOSITE_INDEX_NAME
    )
      add_index(
        :actor_behavior_heavy_snapshots,
        %i[cluster_id analysis_kind],
        unique: true,
        name: COMPOSITE_INDEX_NAME
      )
    end
  end

  def down
    service_rows =
      select_value(
        <<~SQL.squish
          SELECT EXISTS (
            SELECT 1
            FROM actor_behavior_heavy_snapshots
            WHERE analysis_kind <> 'exchange_infrastructure'
          )
        SQL
      )

    if ActiveModel::Type::Boolean.new.cast(service_rows)
      raise ActiveRecord::IrreversibleMigration,
            "service infrastructure snapshots must be removed " \
            "before restoring the exchange-only schema"
    end

    if index_exists?(
      :actor_behavior_heavy_snapshots,
      %i[cluster_id analysis_kind],
      name: COMPOSITE_INDEX_NAME
    )
      remove_index(
        :actor_behavior_heavy_snapshots,
        name: COMPOSITE_INDEX_NAME
      )
    end

    change_column_null(
      :actor_behavior_heavy_snapshots,
      :downstream_cluster_id,
      false
    )

    unless index_exists?(
      :actor_behavior_heavy_snapshots,
      :cluster_id,
      unique: true
    )
      add_index(
        :actor_behavior_heavy_snapshots,
        :cluster_id,
        unique: true,
        name: "idx_behavior_heavy_unique_cluster"
      )
    end
  end
end
