class CreateClusters < ActiveRecord::Migration[8.0]
  def change
    create_table :clusters do |t|
      t.integer :address_count, null: false, default: 0
      t.bigint :total_received_sats, null: false, default: 0
      t.bigint :total_sent_sats, null: false, default: 0
      t.integer :first_seen_height
      t.integer :last_seen_height

      t.timestamps
    end

    add_index :clusters, :first_seen_height
    add_index :clusters, :last_seen_height
  end
end