class ImproveGuidesStructure < ActiveRecord::Migration[8.0]
  def change
    # Publication
    add_column :guides, :status, :string, default: "draft", null: false
    add_column :guides, :featured, :boolean, default: false

    # Organisation
    add_column :guides, :excerpt,  :text
    add_column :guides, :category, :string
    add_column :guides, :app_area, :string
    add_column :guides, :position, :integer, default: 0

    # Index utiles
    add_index :guides, :status
    add_index :guides, :category
    add_index :guides, :app_area
    add_index :guides, :position

    # Migration logique depuis l'existant
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE guides
          SET status = CASE
            WHEN published = true THEN 'published'
            ELSE 'draft'
          END
        SQL
      end
    end

    # Nettoyage legacy
    remove_column :guides, :published, :boolean
    remove_column :guides, :level, :string
  end
end
