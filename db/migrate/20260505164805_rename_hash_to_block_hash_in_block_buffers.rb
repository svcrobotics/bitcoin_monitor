class RenameHashToBlockHashInBlockBuffers < ActiveRecord::Migration[8.0]
  def change
    rename_column :block_buffers, :hash, :block_hash
  end
end