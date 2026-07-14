# frozen_string_literal: true

class CreateAddressSpendProjection < ActiveRecord::Migration[8.0]
  def change
    create_table :address_spend_stats do |t|
      t.references(
        :address,
        null: false,
        foreign_key: {
          on_delete: :cascade
        },
        index: {
          unique: true
        }
      )

      t.bigint(
        :total_sent_sats,
        null: false,
        default: 0
      )

      t.bigint(
        :spent_inputs_count,
        null: false,
        default: 0
      )

      t.integer :first_spent_height
      t.integer :last_spent_height

      t.integer(
        :source_height,
        null: false
      )

      t.string(
        :projection_version,
        null: false
      )

      t.timestamps
    end

    add_index(
      :address_spend_stats,
      :source_height
    )

    add_index(
      :address_spend_stats,
      :last_spent_height
    )

    create_table :address_spend_projection_blocks do |t|
      t.integer(
        :height,
        null: false
      )

      t.string(
        :block_hash,
        null: false
      )

      t.string(
        :status,
        null: false,
        default: "pending"
      )

      t.bigint(
        :input_count,
        null: false,
        default: 0
      )

      t.integer(
        :address_count,
        null: false,
        default: 0
      )

      t.bigint(
        :total_sent_sats,
        null: false,
        default: 0
      )

      t.integer(
        :attempts,
        null: false,
        default: 0
      )

      t.datetime :processing_started_at
      t.datetime :completed_at
      t.text :error_message

      t.jsonb(
        :metadata,
        null: false,
        default: {}
      )

      t.timestamps
    end

    add_index(
      :address_spend_projection_blocks,
      :height,
      unique: true
    )

    add_index(
      :address_spend_projection_blocks,
      [:status, :height]
    )

    add_check_constraint(
      :address_spend_projection_blocks,
      "status IN ('pending', 'processing', 'completed', 'failed')",
      name: "address_spend_projection_blocks_status_check"
    )

    add_check_constraint(
      :address_spend_projection_blocks,
      "height >= 0",
      name: "address_spend_projection_blocks_height_check"
    )

    add_check_constraint(
      :address_spend_projection_blocks,
      "input_count >= 0",
      name: "address_spend_projection_blocks_input_count_check"
    )

    add_check_constraint(
      :address_spend_projection_blocks,
      "address_count >= 0",
      name: "address_spend_projection_blocks_address_count_check"
    )

    add_check_constraint(
      :address_spend_projection_blocks,
      "total_sent_sats >= 0",
      name: "address_spend_projection_blocks_total_sent_sats_check"
    )
  end
end
