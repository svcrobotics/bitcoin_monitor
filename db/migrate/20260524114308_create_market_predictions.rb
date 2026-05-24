class CreateMarketPredictions < ActiveRecord::Migration[8.0]
  def change
    create_table :market_predictions do |t|
      t.string :source, null: false
      t.string :indicator, null: false
      t.string :direction, null: false
      t.integer :confidence, null: false, default: 50

      t.date :predicted_on, null: false
      t.date :target_on, null: false

      t.decimal :btc_price_at_prediction, precision: 20, scale: 8
      t.decimal :btc_price_at_target, precision: 20, scale: 8
      t.decimal :performance_pct, precision: 10, scale: 4

      t.string :result
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :market_predictions, [:source, :indicator, :predicted_on, :target_on], unique: true
    add_index :market_predictions, :result
    add_index :market_predictions, :direction
  end
end