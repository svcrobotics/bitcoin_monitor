class CreateClusterMetrics < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_metrics do |t|
      t.references :cluster, null: false, foreign_key: true
      t.date :snapshot_date
      t.integer :tx_count_24h
      t.integer :tx_count_7d
      t.bigint :sent_sats_24h
      t.bigint :sent_sats_7d
      t.integer :activity_score

      t.timestamps
    end
  end
end
