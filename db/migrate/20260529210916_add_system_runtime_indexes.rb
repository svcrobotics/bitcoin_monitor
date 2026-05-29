class AddSystemRuntimeIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :exchange_observed_utxos, :updated_at, if_not_exists: true
    add_index :cluster_profiles, :updated_at, if_not_exists: true
  end
end