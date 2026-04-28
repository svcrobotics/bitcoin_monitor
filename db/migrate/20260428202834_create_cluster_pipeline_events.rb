class CreateClusterPipelineEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_pipeline_events do |t|
      t.string :event
      t.integer :height
      t.jsonb :payload
      t.datetime :processed_at

      t.timestamps
    end
  end
end
