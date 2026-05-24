class CreateMarketSignals < ActiveRecord::Migration[8.0]
  def change
    create_table :market_signals do |t|
      t.string :source, null: false
      t.string :indicator, null: false
      t.string :direction, null: false
      t.integer :confidence, null: false, default: 50
      t.date :observed_on, null: false
      t.text :reason
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :market_signals, [:source, :indicator, :observed_on], unique: true
    add_index :market_signals, [:indicator, :observed_on]
    add_index :market_signals, :direction
  end
end