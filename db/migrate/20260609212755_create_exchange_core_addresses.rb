class CreateExchangeCoreAddresses < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_core_addresses do |t|
      t.string :address, null: false
      t.bigint :cluster_id, null: false
      t.string :source, null: false, default: "actor_profile_exchange_like"

      t.timestamps
    end

    add_index :exchange_core_addresses, :address, unique: true
    add_index :exchange_core_addresses, :cluster_id
    add_index :exchange_core_addresses, :source
  end
end