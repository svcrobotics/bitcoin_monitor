# frozen_string_literal: true

class ContractClusterCompositionVersion < ActiveRecord::Migration[8.0]
  CONSTRAINT_NAME = "clusters_composition_version_positive"

  def up
    change_column_default(
      :clusters,
      :composition_version,
      from: 0,
      to: 1
    )

    add_check_constraint(
      :clusters,
      "composition_version >= 1",
      name: CONSTRAINT_NAME,
      validate: false
    )
    validate_check_constraint(
      :clusters,
      name: CONSTRAINT_NAME
    )
  end

  def down
    remove_check_constraint(
      :clusters,
      name: CONSTRAINT_NAME
    )
    change_column_default(
      :clusters,
      :composition_version,
      from: 1,
      to: 0
    )
  end
end
