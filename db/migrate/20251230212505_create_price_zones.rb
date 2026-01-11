class CreatePriceZones < ActiveRecord::Migration[8.0]
  def change
    create_table :price_zones do |t|
      t.string  :kind, null: false # "support" | "resistance"

      t.decimal :low_usd,  precision: 20, scale: 8, null: false
      t.decimal :high_usd, precision: 20, scale: 8, null: false

      t.integer :strength, null: false, default: 0
      t.integer :touches_count, null: false, default: 0

      t.string  :timeframe, null: false, default: "1y_daily"
      t.datetime :computed_at, null: false

      t.text :note

      t.timestamps
    end

    add_index :price_zones, :kind
    add_index :price_zones, :computed_at
    add_index :price_zones, [:kind, :timeframe, :computed_at]
  end
end
