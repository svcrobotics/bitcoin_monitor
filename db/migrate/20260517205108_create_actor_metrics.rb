# frozen_string_literal: true

class CreateActorMetrics < ActiveRecord::Migration[8.0]
  def change
    create_table :actor_metrics do |t|
      t.references :cluster, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }

      t.integer :address_count, null: false, default: 0
      t.integer :total_tx_count, null: false, default: 0

      t.bigint :total_received_sats, null: false, default: 0
      t.bigint :total_sent_sats, null: false, default: 0

      t.integer :first_seen_height
      t.integer :last_seen_height
      t.integer :activity_span_blocks

      t.integer :exchange_score, null: false, default: 0
      t.integer :whale_score, null: false, default: 0
      t.integer :service_score, null: false, default: 0

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :actor_metrics, :exchange_score
    add_index :actor_metrics, :whale_score
    add_index :actor_metrics, :service_score
  end
end