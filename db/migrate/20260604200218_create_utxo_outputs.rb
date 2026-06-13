class CreateUtxoOutputs < ActiveRecord::Migration[8.0]
  def change
    create_table :utxo_outputs do |t|
      t.string :txid, null: false
      t.integer :vout, null: false
      t.string :address
      t.decimal :amount_btc, precision: 20, scale: 8
      t.integer :block_height
      t.string :block_hash
      t.datetime :block_time

      t.timestamps
    end

    add_index :utxo_outputs, [:txid, :vout], unique: true
    add_index :utxo_outputs, :address
    add_index :utxo_outputs, :block_height
  end
end