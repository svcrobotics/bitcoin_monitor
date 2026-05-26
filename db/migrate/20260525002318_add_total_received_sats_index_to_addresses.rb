class AddTotalReceivedSatsIndexToAddresses < ActiveRecord::Migration[8.0]
  def change
    add_index :addresses, :total_received_sats
    add_index :addresses, :total_sent_sats
  end
end