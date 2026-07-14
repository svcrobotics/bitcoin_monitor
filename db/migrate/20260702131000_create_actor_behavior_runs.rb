class CreateActorBehaviorRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_behavior_runs do |t|
      t.string :behavior_version, null: false
      t.string :mode, null: false
      t.string :trigger, null: false
      t.integer :requested_limit, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.bigint :duration_ms

      t.integer :selected, null: false, default: 0
      t.integer :missing_selected, null: false, default: 0
      t.integer :stale_selected, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :updated_count, null: false, default: 0
      t.integer :unchanged_count, null: false, default: 0
      t.integer :deferred_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0

      t.jsonb :reasons, null: false, default: {}
      t.string :error_code
      t.text :error_message

      t.integer :actor_profiles_certified_at_start
      t.integer :actor_profile_max_height_at_start
      t.bigint :cluster_processed_tip_at_start

      t.timestamps
    end

    add_index :actor_behavior_runs, :status
    add_index :actor_behavior_runs, :started_at
    add_index :actor_behavior_runs, :finished_at
    add_index :actor_behavior_runs, :behavior_version
    add_index :actor_behavior_runs, :trigger
    add_index :actor_behavior_runs, [:status, :started_at]
  end
end
