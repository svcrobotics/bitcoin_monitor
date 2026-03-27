class CreateScannerCursors < ActiveRecord::Migration[8.0]
  def change
    create_table :scanner_cursors do |t|
      t.string  :name, null: false
      t.integer :last_blockheight
      t.string  :last_blockhash

      t.timestamps
    end

    add_index :scanner_cursors, :name, unique: true
    add_index :scanner_cursors, :last_blockheight
  end
end