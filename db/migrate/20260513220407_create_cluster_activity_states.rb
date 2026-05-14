class CreateClusterActivityStates < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_activity_states do |t|
      t.references :cluster, null: false, foreign_key: true
      t.integer :last_seen_height
      t.datetime :last_seen_at
      t.integer :last_active_height
      t.datetime :last_active_at
      t.integer :inactive_blocks
      t.integer :inactive_seconds
      t.integer :activity_count

      t.timestamps
    end
  end
end
