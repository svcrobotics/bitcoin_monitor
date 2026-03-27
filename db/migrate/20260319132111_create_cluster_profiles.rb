class CreateClusterProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_profiles do |t|
      t.references :cluster, null: false, foreign_key: true
      t.integer :cluster_size
      t.integer :tx_count
      t.bigint :total_sent_sats
      t.integer :first_seen_height
      t.integer :last_seen_height
      t.string :classification
      t.integer :score

      t.timestamps
    end
  end
end
