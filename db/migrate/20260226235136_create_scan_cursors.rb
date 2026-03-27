# db/migrate/XXXXXXXXXXXXXX_create_scan_cursors.rb
class CreateScanCursors < ActiveRecord::Migration[8.0]
  def change
    create_table :scan_cursors do |t|
      t.string :name, null: false
      t.bigint :last_height, null: false, default: 0
      t.timestamps
    end

    add_index :scan_cursors, :name, unique: true
  end
end