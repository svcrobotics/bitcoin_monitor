# frozen_string_literal: true

class CreateClusterProcessedBlocks < ActiveRecord::Migration[8.0]
  TABLE_NAME =
    :cluster_processed_blocks

  REQUIRED_COLUMNS =
    %i[
      height
      block_hash
      status
      scan_result
      cleanup_result
      audit_result
      processed_at
      error_message
      created_at
      updated_at
    ].freeze

  def up
    unless table_exists?(TABLE_NAME)
      create_table TABLE_NAME do |t|
        t.bigint :height, null: false
        t.string :block_hash, null: false
        t.string :status, null: false, default: "processed"
        t.jsonb :scan_result, null: false, default: {}
        t.jsonb :cleanup_result, null: false, default: {}
        t.jsonb :audit_result, null: false, default: {}
        t.datetime :processed_at, null: false
        t.text :error_message

        t.timestamps
      end
    end

    assert_required_columns!
    add_missing_indexes!
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "cluster_processed_blocks is a historical reconciliation migration; rollback must not drop adopted data"
  end

  private

  def assert_required_columns!
    missing =
      REQUIRED_COLUMNS.reject do |column_name|
        column_exists?(
          TABLE_NAME,
          column_name
        )
      end

    return if missing.empty?

    raise ActiveRecord::MigrationError,
          "cluster_processed_blocks schema drift: missing required columns #{missing.join(', ')}"
  end

  def add_missing_indexes!
    add_unique_height_index!

    add_index(TABLE_NAME, :status) unless
      index_exists?(TABLE_NAME, :status)

    add_index(TABLE_NAME, :processed_at) unless
      index_exists?(TABLE_NAME, :processed_at)
  end

  def add_unique_height_index!
    return if index_exists?(
      TABLE_NAME,
      :height,
      unique: true
    )

    if index_exists?(TABLE_NAME, :height)
      raise ActiveRecord::MigrationError,
            "cluster_processed_blocks schema drift: height index exists but is not unique"
    end

    add_index(
      TABLE_NAME,
      :height,
      unique: true
    )
  end
end
