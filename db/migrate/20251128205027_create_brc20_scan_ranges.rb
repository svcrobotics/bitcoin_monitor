# db/migrate/2025xxxxxx_create_brc20_scan_ranges.rb
class CreateBrc20ScanRanges < ActiveRecord::Migration[8.0]
  def change
    create_table :brc20_scan_ranges do |t|
      t.integer  :from_height, null: false
      t.integer  :to_height,   null: false
      t.datetime :scanned_at,  null: false

      t.timestamps
    end

    add_index :brc20_scan_ranges, [:from_height, :to_height]
    add_index :brc20_scan_ranges, :from_height
    add_index :brc20_scan_ranges, :to_height
  end
end
