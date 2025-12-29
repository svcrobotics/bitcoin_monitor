class CreateGuides < ActiveRecord::Migration[8.0]
  def change
    create_table :guides do |t|
      t.string :title
      t.string :slug
      t.string :level
      t.boolean :published
      t.text :content

      t.timestamps
    end
    add_index :guides, :slug
  end
end
