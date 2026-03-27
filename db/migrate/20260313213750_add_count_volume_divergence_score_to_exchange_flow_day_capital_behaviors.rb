class AddCountVolumeDivergenceScoreToExchangeFlowDayCapitalBehaviors < ActiveRecord::Migration[7.1]
  def change
    add_column :exchange_flow_day_capital_behaviors,
               :count_volume_divergence_score,
               :decimal,
               precision: 10,
               scale: 6
  end
end