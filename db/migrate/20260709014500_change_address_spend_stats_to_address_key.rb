# frozen_string_literal: true

class ChangeAddressSpendStatsToAddressKey <
  ActiveRecord::Migration[8.0]

  def up
    add_column(
      :address_spend_stats,
      :address,
      :string
    )

    execute <<~SQL
      UPDATE address_spend_stats
      SET address = addresses.address
      FROM addresses
      WHERE addresses.id =
            address_spend_stats.address_id
    SQL

    missing =
      select_value(<<~SQL).to_i
        SELECT COUNT(*)
        FROM address_spend_stats
        WHERE address IS NULL
           OR address = ''
      SQL

    if missing.positive?
      raise(
        ActiveRecord::MigrationError,
        "#{missing} address_spend_stats rows " \
        "could not be converted to address keys"
      )
    end

    change_column_null(
      :address_spend_stats,
      :address,
      false
    )

    add_index(
      :address_spend_stats,
      :address,
      unique: true
    )

    remove_foreign_key(
      :address_spend_stats,
      column: :address_id
    )

    remove_index(
      :address_spend_stats,
      :address_id
    )

    remove_column(
      :address_spend_stats,
      :address_id
    )
  end

  def down
    add_column(
      :address_spend_stats,
      :address_id,
      :bigint
    )

    execute <<~SQL
      UPDATE address_spend_stats
      SET address_id = addresses.id
      FROM addresses
      WHERE addresses.address =
            address_spend_stats.address
    SQL

    missing =
      select_value(<<~SQL).to_i
        SELECT COUNT(*)
        FROM address_spend_stats
        WHERE address_id IS NULL
      SQL

    if missing.positive?
      raise(
        ActiveRecord::IrreversibleMigration,
        "#{missing} projected addresses do not exist " \
        "in the addresses table"
      )
    end

    change_column_null(
      :address_spend_stats,
      :address_id,
      false
    )

    add_index(
      :address_spend_stats,
      :address_id,
      unique: true
    )

    add_foreign_key(
      :address_spend_stats,
      :addresses,
      column: :address_id,
      on_delete: :cascade
    )

    remove_index(
      :address_spend_stats,
      :address
    )

    remove_column(
      :address_spend_stats,
      :address
    )
  end
end
