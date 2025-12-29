class RelaxVaultFieldsForDescriptorImport < ActiveRecord::Migration[8.0]
  def change
    # Nouvelles règles : l'import Sparrow peut se faire avec descriptor uniquement
    change_column_null :vaults, :pubkey_a, true
    change_column_null :vaults, :pubkey_b, true

    # delay_blocks est lié à l'ancien chemin de secours, on le rend optionnel
    change_column_null :vaults, :delay_blocks, true

    # (Optionnel) si label doit pouvoir être vide à l'import
    # tu peux le garder required si tu veux
    # change_column_null :vaults, :label, true
  end
end
