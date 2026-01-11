class CreateExchangeAddresses < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_addresses do |t|
      t.string  :address, null: false
      t.integer :confidence, null: false, default: 0
      t.integer :occurrences, null: false, default: 0
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.string :source, null: false, default: "whale_alert_inputs"
      t.timestamps
    end

    add_index :exchange_addresses, :address, unique: true
    add_index :exchange_addresses, :confidence
  end
end
