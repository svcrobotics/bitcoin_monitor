class CreateClusterInputs < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_inputs do |t|
      t.integer :block_height, null: false
      t.string :txid, null: false
      t.integer :vout, null: false
      t.string :address
      t.decimal :amount_btc, precision: 20, scale: 8
      t.boolean :spent, null: false, default: false
      t.string :spent_txid
      t.integer :spent_block_height

      t.decimal :address_balance_btc, precision: 20, scale: 8
      t.decimal :address_received_btc, precision: 20, scale: 8
      t.decimal :address_sent_btc, precision: 20, scale: 8

      t.datetime :cluster_processed_at

      t.timestamps
    end

    add_index :cluster_inputs, [:txid, :vout], unique: true
    add_index :cluster_inputs, :block_height
    add_index :cluster_inputs, :address
    add_index :cluster_inputs, :cluster_processed_at
  end
end