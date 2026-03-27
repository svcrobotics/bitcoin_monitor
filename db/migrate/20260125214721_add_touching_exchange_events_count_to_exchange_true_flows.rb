class AddTouchingExchangeEventsCountToExchangeTrueFlows < ActiveRecord::Migration[8.0]
  def change
    add_column :exchange_true_flows, :touching_exchange_events_count, :integer
  end
end
