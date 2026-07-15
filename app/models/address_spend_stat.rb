# frozen_string_literal: true

class AddressSpendStat < ApplicationRecord
  PROJECTION_VERSION = "strict_v2_address_key"

  validates(
    :address,
    presence: true,
    uniqueness: true
  )

  validates(
    :total_sent_sats,
    :spent_inputs_count,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }
  )

  validates(
    :source_height,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }
  )

  validates(
    :first_spent_height,
    :last_spent_height,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    },
    allow_nil: true
  )

  validates(
    :projection_version,
    presence: true
  )

  validate :spent_height_order

  private

  def spent_height_order
    return if first_spent_height.nil?
    return if last_spent_height.nil?
    return if first_spent_height <= last_spent_height

    errors.add(
      :last_spent_height,
      "must be greater than or equal to first_spent_height"
    )
  end
end
