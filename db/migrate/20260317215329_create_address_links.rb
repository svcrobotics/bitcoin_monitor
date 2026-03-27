class CreateAddressLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :address_links do |t|
      t.references :address_a, null: false, foreign_key: { to_table: :addresses }
      t.references :address_b, null: false, foreign_key: { to_table: :addresses }
      t.string :link_type, null: false
      t.string :txid, null: false
      t.integer :block_height

      t.timestamps
    end

    add_index :address_links, :txid
    add_index :address_links, :block_height
    add_index :address_links, [:address_a_id, :address_b_id, :link_type, :txid],
              unique: true,
              name: "idx_address_links_uniqueness"
  end
end