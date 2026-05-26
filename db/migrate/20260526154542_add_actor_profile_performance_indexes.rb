class AddActorProfilePerformanceIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :address_flow_stats, [:cluster_id], if_not_exists: true
    add_index :address_flow_stats, [:cluster_id, :last_seen_at], if_not_exists: true
    add_index :actor_profiles, [:cluster_id], if_not_exists: true
    add_index :actor_profiles, [:classification], if_not_exists: true
    add_index :actor_profiles, [:updated_at], if_not_exists: true
  end
end