class AddExchangeSignalsToWhaleAlerts < ActiveRecord::Migration[8.0]
  def change
    add_column :whale_alerts, :exchange_likelihood, :integer
    add_column :whale_alerts, :exchange_hint, :string
  end
end
