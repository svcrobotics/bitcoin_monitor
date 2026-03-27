class AddTierToWhaleAlerts < ActiveRecord::Migration[8.0]
  def change
    add_column :whale_alerts, :tier, :string
    add_index  :whale_alerts, :tier
  end
end
