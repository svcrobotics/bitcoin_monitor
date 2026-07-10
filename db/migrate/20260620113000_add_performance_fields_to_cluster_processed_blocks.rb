# frozen_string_literal: true

class AddPerformanceFieldsToClusterProcessedBlocks < ActiveRecord::Migration[8.0]
  TABLE_NAME =
    :cluster_processed_blocks

  def up
    add_column_unless_present(
      :processing_started_at,
      :datetime
    )
    add_column_unless_present(
      :duration_ms,
      :integer
    )
    add_column_unless_present(
      :stage_timings,
      :jsonb,
      null: false,
      default: {}
    )

    unless index_exists?(
      TABLE_NAME,
      :processing_started_at
    )
      add_index(
        TABLE_NAME,
        :processing_started_at
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "cluster_processed_blocks performance fields are historical reconciliation columns; rollback must not remove adopted data"
  end

  private

  def add_column_unless_present(column_name, type, **options)
    if column_exists?(
      TABLE_NAME,
      column_name
    )
      assert_column_type!(
        column_name,
        type
      )
      return
    end

    add_column(
      TABLE_NAME,
      column_name,
      type,
      **options
    )
  end

  def assert_column_type!(column_name, expected_type)
    actual_type =
      column_for(
        column_name
      )&.type

    return if actual_type == expected_type

    raise ActiveRecord::MigrationError,
          "cluster_processed_blocks schema drift: #{column_name} has type #{actual_type.inspect}, expected #{expected_type.inspect}"
  end

  def column_for(column_name)
    columns(TABLE_NAME).find do |column|
      column.name == column_name.to_s
    end
  end
end
