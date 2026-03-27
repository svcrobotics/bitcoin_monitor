class SecureGuidesSlug < ActiveRecord::Migration[8.0]
  def change
    # empêcher slug NULL
    change_column_null :guides, :slug, false

    # supprimer l’index existant
    remove_index :guides, :slug

    # index unique (obligatoire)
    add_index :guides, :slug, unique: true
  end
end
