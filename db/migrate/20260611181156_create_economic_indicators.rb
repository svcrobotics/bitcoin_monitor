class CreateEconomicIndicators < ActiveRecord::Migration[8.0]
  def change
    create_table :economic_indicators do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.string :source, null: false
      t.date :observed_on, null: false
      t.decimal :value, precision: 20, scale: 8, null: false
      t.jsonb :raw_payload, default: {}

      t.timestamps
    end

    add_index :economic_indicators, [:code, :observed_on], unique: true
  end
end