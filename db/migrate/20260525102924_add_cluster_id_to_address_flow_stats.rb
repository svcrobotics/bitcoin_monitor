class AddClusterIdToAddressFlowStats < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :address_flow_stats, :cluster_id, :integer unless column_exists?(:address_flow_stats, :cluster_id)

    add_index :address_flow_stats, :cluster_id,
      algorithm: :concurrently,
      if_not_exists: true

    add_index :address_flow_stats, [:cluster_id, :updated_at],
      algorithm: :concurrently,
      if_not_exists: true
  end
end