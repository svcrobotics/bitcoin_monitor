# frozen_string_literal: true

class AllowNullBackfillGenerationAndAddStaleRunState < ActiveRecord::Migration[8.0]
  RUN_STATUSES =
    %w[pending running paused completed failed stale].freeze

  def up
    change_column_null(
      :cluster_transaction_projection_backfill_items,
      :projection_generation_id,
      true
    )

    change_table :cluster_transaction_projection_backfill_runs do |t|
      t.datetime :stale_at
      t.string :stale_reason
    end

    remove_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      name: "ctp_backfill_runs_status_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      "status IN (#{quoted(RUN_STATUSES)})",
      name: "ctp_backfill_runs_status_check"
    )
  end

  def down
    remove_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      name: "ctp_backfill_runs_status_check"
    )

    add_check_constraint(
      :cluster_transaction_projection_backfill_runs,
      "status IN (#{quoted(%w[pending running paused completed failed])})",
      name: "ctp_backfill_runs_status_check"
    )

    remove_column :cluster_transaction_projection_backfill_runs, :stale_reason
    remove_column :cluster_transaction_projection_backfill_runs, :stale_at

    change_column_null(
      :cluster_transaction_projection_backfill_items,
      :projection_generation_id,
      false
    )
  end

  private

  def quoted(values)
    values.map { |value| quote(value) }.join(", ")
  end
end
