class CreateActorBehaviorSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_behavior_snapshots do |t|
      t.references(
        :cluster,
        null: false,
        type: :bigint,
        index: false,
        foreign_key: { on_delete: :cascade }
      )

      t.references(
        :actor_profile,
        null: false,
        type: :bigint,
        index: false,
        foreign_key: { on_delete: :cascade }
      )

      t.string :profile_version, null: false
      t.integer :profile_height, null: false
      t.bigint :cluster_composition_version, null: false
      t.string :profile_fingerprint, null: false
      t.string :behavior_version, null: false
      t.string :status, null: false
      t.jsonb :signals, null: false, default: {}
      t.jsonb :scores, null: false, default: {}
      t.jsonb :evidence, null: false, default: {}
      t.datetime :computed_at, null: false

      t.timestamps
    end

    add_index(
      :actor_behavior_snapshots,
      :cluster_id,
      unique: true
    )

    add_index(
      :actor_behavior_snapshots,
      :actor_profile_id
    )

    add_index(
      :actor_behavior_snapshots,
      :status
    )

    add_index(
      :actor_behavior_snapshots,
      :profile_height
    )

    add_index(
      :actor_behavior_snapshots,
      :profile_fingerprint
    )

    add_index(
      :actor_behavior_snapshots,
      [
        :cluster_id,
        :profile_height,
        :cluster_composition_version
      ],
      name: "idx_actor_behavior_snapshot_checkpoint"
    )
  end
end
