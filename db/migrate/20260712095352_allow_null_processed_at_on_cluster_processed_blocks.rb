# frozen_string_literal: true

class AllowNullProcessedAtOnClusterProcessedBlocks < ActiveRecord::Migration[8.0]
  def up
    change_column_null :cluster_processed_blocks, :processed_at, true
  end

  def down
    change_column_null :cluster_processed_blocks, :processed_at, false
  end
end
