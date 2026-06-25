# frozen_string_literal: true

class CreateClusterCoverageBlocks < ActiveRecord::Migration[8.0]
  def change
    create_table :cluster_coverage_blocks do |t|
      t.bigint :height,
        null: false

      t.string :block_hash,
        null: false

      t.string :status,
        null: false,
        default: "pending"

      t.bigint :max_tx_output_id

      t.bigint :after_tx_output_id

      t.integer :expected_outputs_count,
        null: false,
        default: 0

      t.integer :processed_outputs_count,
        null: false,
        default: 0

      t.integer :expected_address_outputs_count,
        null: false,
        default: 0

      t.integer :processed_address_outputs_count,
        null: false,
        default: 0

      t.integer :scripts_without_address_count,
        null: false,
        default: 0

      t.integer :addresses_created_count,
        null: false,
        default: 0

      t.integer :singleton_clusters_created_count,
        null: false,
        default: 0

      t.integer :pages_processed,
        null: false,
        default: 0

      t.integer :attempts,
        null: false,
        default: 0

      t.datetime :started_at

      t.datetime :completed_at

      t.text :last_error

      t.jsonb :metadata,
        null: false,
        default: {}

      t.timestamps
    end

    add_index(
      :cluster_coverage_blocks,
      :height,
      unique: true
    )

    add_index(
      :cluster_coverage_blocks,
      [:status, :height]
    )
  end
end
