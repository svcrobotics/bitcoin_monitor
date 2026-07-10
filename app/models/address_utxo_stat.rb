# frozen_string_literal: true

class AddressUtxoStat < ApplicationRecord
  PROJECTION_VERSION =
    "strict_v1_address_utxo_projection"

  validates :address,
    presence: true,
    uniqueness: true

  validates :projection_version,
    presence: true

  validates :total_received_sats,
    :current_balance_sats,
    :live_utxo_count,
    :received_output_count,
    :last_changed_height,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }

  validates :first_received_height,
    :last_received_height,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    },
    allow_nil: true

  validate :current_balance_does_not_exceed_received
  validate :received_height_order

  private

  def current_balance_does_not_exceed_received
    return if current_balance_sats.blank?
    return if total_received_sats.blank?
    return if current_balance_sats <= total_received_sats

    errors.add(
      :current_balance_sats,
      :less_than_or_equal_to,
      count: total_received_sats
    )
  end

  def received_height_order
    return if first_received_height.nil?
    return if last_received_height.nil?
    return if first_received_height <= last_received_height

    errors.add(
      :last_received_height,
      :greater_than_or_equal_to,
      count: first_received_height
    )
  end
end
