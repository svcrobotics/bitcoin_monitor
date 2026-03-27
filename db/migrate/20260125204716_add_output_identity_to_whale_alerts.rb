class AddOutputIdentityToWhaleAlerts < ActiveRecord::Migration[8.0]
  def change
    add_column :whale_alerts, :largest_output_address, :string
    add_column :whale_alerts, :largest_output_vout, :integer
    add_column :whale_alerts, :largest_output_desc, :text
  end
end
