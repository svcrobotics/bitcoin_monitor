class CreateVaultAddresses < ActiveRecord::Migration[8.0]
  def change
    create_table :vault_addresses do |t|
      t.references :vault, null: false, foreign_key: true

      # "receive" ou "change"
      t.string  :kind,  null: false

      # index dérivation (0..scan_range)
      t.integer :index, null: false

      # adresse bech32 (bc1..., tb1..., bcrt1...)
      t.string  :address, null: false

      # méta (optionnel mais pratique pour l'observation)
      t.datetime :last_seen_at
      t.integer  :last_seen_block

      t.timestamps
    end

    # Un wallet ne peut pas avoir 2 fois la même adresse pour (kind,index)
    add_index :vault_addresses, [:vault_id, :kind, :index], unique: true

    # Une adresse ne doit appartenir qu’à un seul vault (évite tes soucis de doublons)
    add_index :vault_addresses, :address, unique: true

    add_index :vault_addresses, :kind
    add_index :vault_addresses, :last_seen_block
  end
end
