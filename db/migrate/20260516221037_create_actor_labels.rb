class CreateActorLabels < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_labels do |t|
      t.references :cluster, null: false, foreign_key: true

      t.string :label, null: false
      t.integer :confidence, null: false, default: 0
      t.string :source, null: false, default: "cluster_profile"

      t.jsonb :metadata, null: false, default: {}

      t.datetime :first_seen_at
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :actor_labels, [:cluster_id, :label, :source], unique: true
    add_index :actor_labels, :label
    add_index :actor_labels, :confidence
  end
end