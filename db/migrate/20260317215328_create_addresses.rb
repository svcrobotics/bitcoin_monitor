class CreateAddresses < ActiveRecord::Migration[8.0]
  def change
    create_table :addresses do |t|
      t.string :address, null: false
      t.integer :first_seen_height
      t.integer :last_seen_height
      t.bigint :total_received_sats, null: false, default: 0
      t.bigint :total_sent_sats, null: false, default: 0
      t.integer :tx_count, null: false, default: 0
      t.references :cluster, null: true, foreign_key: true

      t.timestamps
    end

    add_index :addresses, :address, unique: true
    add_index :addresses, :first_seen_height
    add_index :addresses, :last_seen_height
  end
end