class CreateExchangeFlowDayBehavior < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_flow_day_behavior do |t|
      t.date :day, null: false

      # Deposit ratios
      t.decimal :retail_deposit_ratio, precision: 10, scale: 6, default: 0
      t.decimal :retail_deposit_volume_ratio, precision: 10, scale: 6, default: 0

      t.decimal :whale_deposit_ratio, precision: 10, scale: 6, default: 0
      t.decimal :whale_deposit_volume_ratio, precision: 10, scale: 6, default: 0

      t.decimal :institutional_deposit_ratio, precision: 10, scale: 6, default: 0
      t.decimal :institutional_deposit_volume_ratio, precision: 10, scale: 6, default: 0

      # Withdrawal ratios
      t.decimal :retail_withdrawal_ratio, precision: 10, scale: 6, default: 0
      t.decimal :retail_withdrawal_volume_ratio, precision: 10, scale: 6, default: 0

      t.decimal :whale_withdrawal_ratio, precision: 10, scale: 6, default: 0
      t.decimal :whale_withdrawal_volume_ratio, precision: 10, scale: 6, default: 0

      t.decimal :institutional_withdrawal_ratio, precision: 10, scale: 6, default: 0
      t.decimal :institutional_withdrawal_volume_ratio, precision: 10, scale: 6, default: 0

      # Scores
      t.decimal :deposit_concentration_score, precision: 10, scale: 6, default: 0
      t.decimal :withdrawal_concentration_score, precision: 10, scale: 6, default: 0

      t.decimal :distribution_score, precision: 10, scale: 6, default: 0
      t.decimal :accumulation_score, precision: 10, scale: 6, default: 0

      t.decimal :behavior_score, precision: 10, scale: 6, default: 0

      t.datetime :computed_at

      t.timestamps
    end

    add_index :exchange_flow_day_behavior, :day, unique: true
  end
end