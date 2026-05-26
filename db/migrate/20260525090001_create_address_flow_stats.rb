class CreateAddressFlowStats < ActiveRecord::Migration[8.0]
  def change
    create_table :address_flow_stats do |t|
      t.string :address, null: false
      t.decimal :received_btc, precision: 24, scale: 8, default: 0, null: false
      t.decimal :sent_btc, precision: 24, scale: 8, default: 0, null: false
      t.decimal :net_btc, precision: 24, scale: 8, default: 0, null: false
      t.integer :tx_count, default: 0, null: false
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :address_flow_stats, :address, unique: true
    add_index :address_flow_stats, :received_btc
    add_index :address_flow_stats, :sent_btc
    add_index :address_flow_stats, :net_btc
  end
end