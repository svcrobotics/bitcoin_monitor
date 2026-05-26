class AddActorProfileIdToActorLabels < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :actor_labels, :actor_profile_id, :bigint unless column_exists?(:actor_labels, :actor_profile_id)

    add_index :actor_labels, :actor_profile_id,
      algorithm: :concurrently,
      if_not_exists: true
  end
end