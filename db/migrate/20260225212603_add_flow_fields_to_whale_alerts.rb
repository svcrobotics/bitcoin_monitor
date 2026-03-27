class AddFlowFieldsToWhaleAlerts < ActiveRecord::Migration[8.0]
  def change
    add_column :whale_alerts, :flow_kind, :string
    add_column :whale_alerts, :flow_confidence, :integer
    add_column :whale_alerts, :actor_band, :string
    add_column :whale_alerts, :flow_reasons, :text
    add_column :whale_alerts, :flow_scores, :jsonb
  end
end
