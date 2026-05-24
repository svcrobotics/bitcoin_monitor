class CreateMacroIndicators < ActiveRecord::Migration[8.0]
  def change
    create_table :macro_indicators do |t|
      t.string :source, null: false
      t.string :code, null: false
      t.date :observed_on, null: false
      t.decimal :value, precision: 20, scale: 8, null: false

      t.timestamps
    end

    add_index :macro_indicators, [:source, :code, :observed_on], unique: true
    add_index :macro_indicators, [:code, :observed_on]
  end
end