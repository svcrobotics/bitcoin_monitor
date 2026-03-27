class CreateExchangeOutflowBreakdowns < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_outflow_breakdowns do |t|
      t.date    :day, null: false
      t.string  :scope, null: false
      t.string  :bucket, null: false

      t.decimal :btc, precision: 20, scale: 8, null: false, default: 0
      t.decimal :pct, precision: 10, scale: 4

      t.jsonb   :meta, null: false, default: {}

      t.datetime :computed_at
      t.timestamps
    end

    add_index :exchange_outflow_breakdowns, [:day, :scope, :bucket],
              unique: true,
              name: "idx_outflow_breakdowns_unique"

    add_index :exchange_outflow_breakdowns, :day
    add_index :exchange_outflow_breakdowns, :scope
  end
end