class RenameExchangeFlowDayBehaviorTable < ActiveRecord::Migration[8.0]
  def change
    rename_table :exchange_flow_day_behavior, :exchange_flow_day_behaviors
  end
end