class CreateVaults < ActiveRecord::Migration[8.0] # ou ta version
  def change
    create_table :vaults do |t|
      # Nom lisible (ex : "Coffre long terme", "Coffre héritage")
      t.string  :label, null: false

      # Clé publique principale (A) – pour l’instant en hex compressé 33 octets
      t.string  :pubkey_a, null: false

      # Clé publique de secours (B) – on pourra évoluer vers B1/B2 ensuite
      t.string  :pubkey_b, null: false

      # Délai de sécurité en blocs (par ex 4320 ≈ 30 jours)
      t.integer :delay_blocks, null: false, default: 4320

      # Miniscript logique (facultatif au début, on le remplira plus tard)
      t.text    :miniscript

      # Descriptor complet (ex: tr(...) ou wsh(...))
      t.text    :descriptor

      # Script hex taproot généré (ou script-path)
      t.text    :script_hex

      # Adresse Taproot bc1p... du vault
      t.string  :address

      # Réseau (mainnet, testnet, regtest) pour pouvoir tester
      t.string  :network, null: false, default: "mainnet"

      # Statut du vault (draft, active, closed, etc.)
      t.string  :status, null: false, default: "draft"

      t.timestamps
    end

    add_index :vaults, :address, unique: true
    add_index :vaults, :status
    add_index :vaults, :network
  end
end
