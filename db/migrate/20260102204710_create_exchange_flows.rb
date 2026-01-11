class CreateExchangeFlows < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_flows do |t|
      t.date :day, null: false

      t.decimal :inflow_btc, precision: 16, scale: 8, null: false, default: 0

      t.decimal :avg7,    precision: 16, scale: 8
      t.decimal :avg30,   precision: 16, scale: 8
      t.decimal :avg200,  precision: 16, scale: 8
      t.decimal :ratio30, precision: 10, scale: 4

      t.string :status # "green" / "amber" / "red"
      t.timestamps
    end

    add_index :exchange_flows, :day, unique: true
  end
end
