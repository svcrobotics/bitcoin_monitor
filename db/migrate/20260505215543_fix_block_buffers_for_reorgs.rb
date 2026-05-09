# frozen_string_literal: true

class FixBlockBuffersForReorgs < ActiveRecord::Migration[8.0]
  def change
    remove_index :block_buffers, :height if index_exists?(:block_buffers, :height, unique: true)

    add_column :block_buffers, :is_orphan, :boolean, null: false, default: false unless column_exists?(:block_buffers, :is_orphan)

    add_index :block_buffers, :height unless index_exists?(:block_buffers, :height)
    add_index :block_buffers, [:height, :status] unless index_exists?(:block_buffers, [:height, :status])
    add_index :block_buffers, [:is_orphan, :height] unless index_exists?(:block_buffers, [:is_orphan, :height])
  end
end