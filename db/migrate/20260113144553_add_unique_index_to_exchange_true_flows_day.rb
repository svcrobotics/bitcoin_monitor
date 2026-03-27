class AddUniqueIndexToExchangeTrueFlowsDay < ActiveRecord::Migration[8.0]
  def change
    add_index :exchange_true_flows, :day, unique: true
  end
end
