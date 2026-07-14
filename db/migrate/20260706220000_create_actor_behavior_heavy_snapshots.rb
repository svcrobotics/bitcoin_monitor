# frozen_string_literal: true

class CreateActorBehaviorHeavySnapshots <
  ActiveRecord::Migration[8.0]

  def change
    create_table :actor_behavior_heavy_snapshots do |t|
      t.references(
        :cluster,
        null: false,
        foreign_key: true,
        index: false
      )

      t.references(
        :actor_profile,
        null: false,
        foreign_key: true
      )

      t.references(
        :actor_behavior_snapshot,
        null: false,
        foreign_key: true,
        index: {
          name:
            "idx_behavior_heavy_on_strict_snapshot"
        }
      )

      t.references(
        :downstream_cluster,
        null: false,
        foreign_key: {
          to_table: :clusters
        }
      )

      t.string(
        :analysis_kind,
        null: false,
        default: "exchange_infrastructure"
      )

      t.string(
        :heavy_version,
        null: false
      )

      t.string(
        :status,
        null: false
      )

      t.string(
        :source_profile_fingerprint,
        null: false
      )

      t.integer(
        :source_profile_height,
        null: false
      )

      t.integer(
        :source_cluster_composition_version,
        null: false
      )

      t.string(
        :source_behavior_version,
        null: false
      )

      t.integer(
        :window_from_height,
        null: false
      )

      t.integer(
        :window_to_height,
        null: false
      )

      t.jsonb(
        :signals,
        null: false,
        default: {}
      )

      t.jsonb(
        :scores,
        null: false,
        default: {}
      )

      t.jsonb(
        :evidence,
        null: false,
        default: {}
      )

      t.string(
        :evidence_fingerprint,
        null: false
      )

      t.datetime(
        :computed_at,
        null: false
      )

      t.string :error_code
      t.text :error_message

      t.timestamps
    end

    add_index(
      :actor_behavior_heavy_snapshots,
      :cluster_id,
      unique: true,
      name:
        "idx_behavior_heavy_unique_cluster"
    )

    add_index(
      :actor_behavior_heavy_snapshots,
      [
        :status,
        :window_to_height
      ],
      name:
        "idx_behavior_heavy_status_height"
    )

    add_index(
      :actor_behavior_heavy_snapshots,
      :heavy_version,
      name:
        "idx_behavior_heavy_version"
    )

    add_index(
      :actor_behavior_heavy_snapshots,
      :evidence_fingerprint,
      name:
        "idx_behavior_heavy_fingerprint"
    )
  end
end
