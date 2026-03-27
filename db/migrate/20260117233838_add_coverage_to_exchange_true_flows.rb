class AddCoverageToExchangeTrueFlows < ActiveRecord::Migration[8.0]
  def change
    add_column :exchange_true_flows, :covered, :boolean, null: false, default: false
    add_column :exchange_true_flows, :events_count, :integer
    add_index  :exchange_true_flows, :day, unique: true unless index_exists?(:exchange_true_flows, :day, unique: true)
  end
end
