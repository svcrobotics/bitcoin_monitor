class AddAddressLookupIndexForActorProfileDeltas < ActiveRecord::Migration[8.0]
  def change
    add_index :addresses, :address, if_not_exists: true
    add_index :addresses, [:address, :cluster_id], if_not_exists: true
  end
end