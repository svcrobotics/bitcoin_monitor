# frozen_string_literal: true

class AddStrictMetricsToBlockBuffers <
  ActiveRecord::Migration[8.0]

  def change
    add_column(
      :block_buffers,
      :strict_metrics,
      :jsonb,
      null: false,
      default: {}
    )
  end
end
