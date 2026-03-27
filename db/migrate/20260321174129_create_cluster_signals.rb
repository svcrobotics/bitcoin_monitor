class CreateClusterSignals < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_signals do |t|
      t.references :cluster, null: false, foreign_key: true
      t.date :snapshot_date
      t.string :signal_type
      t.string :severity
      t.integer :score
      t.jsonb :metadata

      t.timestamps
    end
  end
end
