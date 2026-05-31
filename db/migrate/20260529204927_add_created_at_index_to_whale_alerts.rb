class AddCreatedAtIndexToWhaleAlerts < ActiveRecord::Migration[8.0]
  def change
    add_index :whale_alerts, :created_at, if_not_exists: true
  end
end