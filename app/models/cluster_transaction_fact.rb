# frozen_string_literal: true

class ClusterTransactionFact < ApplicationRecord
  self.primary_key = nil

  belongs_to(
    :projection_generation,
    class_name: "ClusterTransactionProjectionGeneration",
    inverse_of: :facts
  )

  validates :projection_generation_id,
    :txid,
    presence: true

  validates :txid,
    length: {
      is: 32
    }

  validates :received_height,
    :spent_height,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0,
      allow_nil: true
    }

  validate :received_or_spent_height_present

  private

  def received_or_spent_height_present
    return if received_height.present? || spent_height.present?

    errors.add(:base, :transaction_fact_without_activity)
  end
end
