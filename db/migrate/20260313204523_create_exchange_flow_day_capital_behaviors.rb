class CreateExchangeFlowDayCapitalBehaviors < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_flow_day_capital_behaviors do |t|
      t.date :day, null: false

      t.decimal :retail_deposit_capital_ratio, precision: 10, scale: 6
      t.decimal :whale_deposit_capital_ratio, precision: 10, scale: 6
      t.decimal :institutional_deposit_capital_ratio, precision: 10, scale: 6

      t.decimal :retail_withdrawal_capital_ratio, precision: 10, scale: 6
      t.decimal :whale_withdrawal_capital_ratio, precision: 10, scale: 6
      t.decimal :institutional_withdrawal_capital_ratio, precision: 10, scale: 6

      t.decimal :capital_dominance_score, precision: 10, scale: 6
      t.decimal :whale_distribution_score, precision: 10, scale: 6
      t.decimal :whale_accumulation_score, precision: 10, scale: 6
      t.decimal :capital_behavior_score, precision: 10, scale: 6

      t.datetime :computed_at

      t.timestamps
    end

    add_index :exchange_flow_day_capital_behaviors, :day, unique: true
  end
end