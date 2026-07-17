# frozen_string_literal: true

class CreateLayer1AuditOperationalEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :layer1_audit_operational_events do |t|
      t.string :event_type, null: false
      t.string :severity, null: false
      t.bigint :audited_height
      t.integer :defer_attempt
      t.string :sidekiq_jid
      t.string :error_class
      t.datetime :occurred_at, precision: 6, null: false
      t.jsonb :metadata, default: {}, null: false
    end

    add_index :layer1_audit_operational_events, :occurred_at,
      name: "idx_layer1_audit_events_occurred_at"
    add_index :layer1_audit_operational_events, [ :event_type, :occurred_at ],
      name: "idx_layer1_audit_events_type_occurred_at"
    add_index :layer1_audit_operational_events, [ :audited_height, :occurred_at ],
      name: "idx_layer1_audit_events_height_occurred_at"

    add_check_constraint :layer1_audit_operational_events,
      "audited_height IS NULL OR audited_height >= 0",
      name: "layer1_audit_events_height_check"
    add_check_constraint :layer1_audit_operational_events,
      "defer_attempt IS NULL OR defer_attempt >= 0",
      name: "layer1_audit_events_attempt_check"
    add_check_constraint :layer1_audit_operational_events,
      "jsonb_typeof(metadata) = 'object'",
      name: "layer1_audit_events_metadata_object_check"
  end
end
