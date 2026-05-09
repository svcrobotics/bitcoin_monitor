class AddRecoveryFieldsToBlockBuffers < ActiveRecord::Migration[8.0]
  def change
    add_column :block_buffers, :attempts, :integer, null: false, default: 0

    add_column :block_buffers, :processing_started_at, :datetime
    add_column :block_buffers, :processed_at, :datetime
    add_column :block_buffers, :failed_at, :datetime
    add_column :block_buffers, :last_heartbeat_at, :datetime

    add_column :block_buffers, :duration_ms, :integer
    add_column :block_buffers, :rpc_duration_ms, :integer
    add_column :block_buffers, :parse_duration_ms, :integer
    add_column :block_buffers, :db_duration_ms, :integer
    add_column :block_buffers, :flush_duration_ms, :integer

    add_column :block_buffers, :error_class, :string
    add_column :block_buffers, :error_message, :text

    add_index :block_buffers, :processing_started_at
    add_index :block_buffers, :last_heartbeat_at
    add_index :block_buffers, :processed_at
    add_index :block_buffers, :failed_at
  end
end