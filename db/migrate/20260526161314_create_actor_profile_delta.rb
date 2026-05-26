class CreateActorProfileDelta < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_profile_deltas do |t|
      t.references :cluster, null: false, foreign_key: true

      t.integer :block_height, null: false

      t.decimal :received_btc_delta, precision: 24, scale: 8, default: 0, null: false
      t.decimal :sent_btc_delta, precision: 24, scale: 8, default: 0, null: false
      t.decimal :net_btc_delta, precision: 24, scale: 8, default: 0, null: false

      t.integer :tx_count_delta, default: 0, null: false

      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.datetime :processed_at

      t.timestamps
    end

    add_index :actor_profile_deltas, [:cluster_id, :block_height]
    add_index :actor_profile_deltas, :processed_at
  end
end