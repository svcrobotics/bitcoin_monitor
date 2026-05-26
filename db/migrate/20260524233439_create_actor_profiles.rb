class CreateActorProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_profiles do |t|
      t.references :cluster, null: false, foreign_key: true
      t.decimal :balance_btc
      t.decimal :total_received_btc
      t.decimal :total_sent_btc
      t.decimal :net_btc
      t.integer :tx_count
      t.integer :inflow_count
      t.integer :outflow_count
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.integer :accumulation_score
      t.integer :distribution_score
      t.integer :exchange_score
      t.integer :whale_score
      t.integer :etf_score
      t.integer :service_score
      t.string :classification
      t.jsonb :traits
      t.jsonb :metadata

      t.timestamps
    end
  end
end
