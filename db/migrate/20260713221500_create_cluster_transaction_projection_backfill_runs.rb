# frozen_string_literal: true

class CreateClusterTransactionProjectionBackfillRuns < ActiveRecord::Migration[8.0]
  RUN_STATUSES = %w[pending running paused completed failed].freeze
  ITEM_STATUSES =
    %w[pending building paused ready_to_certify certified stale failed].freeze
  ITEM_STAGES =
    %w[
      cluster_inputs_received
      utxo_outputs_received
      cluster_inputs_spent
      counter_audit
      certification
    ].freeze

  def change
    validate_check_constraint(
      :clusters,
      name: "clusters_composition_version_positive"
    )

    change_table :cluster_transaction_projection_generations do |t|
      t.string :source, null: false, default: "manual"
      t.integer :base_checkpoint_height
      t.string :base_checkpoint_hash
    end

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE cluster_transaction_projection_generations
          SET
            base_checkpoint_height = checkpoint_height,
            base_checkpoint_hash = checkpoint_hash
          WHERE base_checkpoint_height IS NULL
             OR base_checkpoint_hash IS NULL
        SQL
      end
    end

    change_column_null(
      :cluster_transaction_projection_generations,
      :base_checkpoint_height,
      false
    )

    change_column_null(
      :cluster_transaction_projection_generations,
      :base_checkpoint_hash,
      false
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "BTRIM(source) <> ''",
      name: "ctp_generations_source_present"
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "base_checkpoint_height >= 0",
      name: "ctp_generations_base_height_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "BTRIM(base_checkpoint_hash) <> ''",
      name: "ctp_generations_base_hash_present"
    )

    add_check_constraint(
      :cluster_transaction_projection_generations,
      "base_checkpoint_height <= checkpoint_height",
      name: "ctp_generations_base_before_checkpoint"
    )

    create_table :cluster_transaction_projection_backfill_runs do |t|
      t.integer :target_checkpoint_height, null: false
      t.string :target_checkpoint_hash, null: false
      t.string :status, null: false, default: "pending"
      t.string :source, null: false, default: "pilot_backfill"
      t.datetime :started_at
      t.datetime :paused_at
      t.datetime :completed_at
      t.text :last_error

      t.timestamps
    end

    add_index(
      :cluster_transaction_projection_backfill_runs,
      [:status, :target_checkpoint_height],
      name: "idx_ctp_backfill_runs_status_checkpoint"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      "target_checkpoint_height >= 0",
      name: "ctp_backfill_runs_checkpoint_height_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      "BTRIM(target_checkpoint_hash) <> ''",
      name: "ctp_backfill_runs_checkpoint_hash_present"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      "status IN (#{quoted(RUN_STATUSES)})",
      name: "ctp_backfill_runs_status_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      "BTRIM(source) <> ''",
      name: "ctp_backfill_runs_source_present"
    )

    create_table :cluster_transaction_projection_backfill_items do |t|
      t.references(
        :run,
        null: false,
        foreign_key: {
          to_table: :cluster_transaction_projection_backfill_runs,
          on_delete: :cascade
        },
        index: false
      )
      t.bigint :cluster_id, null: false
      t.bigint :composition_version, null: false
      t.references(
        :projection_generation,
        null: false,
        foreign_key: {
          to_table: :cluster_transaction_projection_generations,
          on_delete: :cascade
        },
        index: false
      )
      t.string :status, null: false, default: "pending"
      t.string :stage, null: false, default: "cluster_inputs_received"
      t.jsonb :source_cursor, null: false, default: {}
      t.bigint :rows_scanned, null: false, default: 0
      t.bigint :facts_written, null: false, default: 0
      t.jsonb :metrics, null: false, default: {}
      t.datetime :started_at
      t.datetime :completed_at
      t.text :last_error

      t.timestamps
    end

    add_index(
      :cluster_transaction_projection_backfill_items,
      [:run_id, :cluster_id],
      unique: true,
      name: "idx_ctp_backfill_items_run_cluster"
    )

    add_index(
      :cluster_transaction_projection_backfill_items,
      [:status, :stage],
      name: "idx_ctp_backfill_items_status_stage"
    )

    add_index(
      :cluster_transaction_projection_backfill_items,
      :projection_generation_id,
      name: "idx_ctp_backfill_items_generation"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_items,
      "composition_version >= 1",
      name: "ctp_backfill_items_revision_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_items,
      "status IN (#{quoted(ITEM_STATUSES)})",
      name: "ctp_backfill_items_status_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_items,
      "stage IN (#{quoted(ITEM_STAGES)})",
      name: "ctp_backfill_items_stage_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_items,
      "rows_scanned >= 0",
      name: "ctp_backfill_items_rows_scanned_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_items,
      "facts_written >= 0",
      name: "ctp_backfill_items_facts_written_check"
    )

    create_table :cluster_transaction_projection_backfill_addresses do |t|
      t.references(
        :run,
        null: false,
        foreign_key: {
          to_table: :cluster_transaction_projection_backfill_runs,
          on_delete: :cascade
        },
        index: false
      )
      t.bigint :cluster_id, null: false
      t.bigint :address_id, null: false
      t.string :address, null: false
      t.bigint :composition_version, null: false

      t.timestamps
    end

    add_index(
      :cluster_transaction_projection_backfill_addresses,
      [:run_id, :cluster_id, :address],
      unique: true,
      name: "idx_ctp_backfill_addresses_run_cluster_address"
    )

    add_index(
      :cluster_transaction_projection_backfill_addresses,
      [:run_id, :address],
      name: "idx_ctp_backfill_addresses_run_address"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_addresses,
      "composition_version >= 1",
      name: "ctp_backfill_addresses_revision_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_addresses,
      "BTRIM(address) <> ''",
      name: "ctp_backfill_addresses_address_present"
    )
  end

  private

  def quoted(values)
    values.map { |value| quote(value) }.join(", ")
  end
end
