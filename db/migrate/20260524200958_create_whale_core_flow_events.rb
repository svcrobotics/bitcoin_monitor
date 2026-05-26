class CreateWhaleCoreFlowEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :whale_core_flow_events do |t|
      t.integer :block_height
      t.string :block_hash
      t.string :txid
      t.string :address
      t.integer :cluster_id
      t.string :direction
      t.decimal :amount_btc, precision: 20, scale: 8, null: false, default: 0
      t.datetime :event_time
      t.string :source
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
  end
end
