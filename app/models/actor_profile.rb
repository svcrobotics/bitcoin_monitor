# frozen_string_literal: true

class ActorProfile < ApplicationRecord
  CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH =
    "activity_since_epoch"

  belongs_to :cluster

  validates :cluster_id,
    presence: true,
    uniqueness: true

  validates :certification_epoch_height,
    numericality: {
      only_integer: true,
      greater_than: 0
    },
    allow_nil: true

  validate :certification_fields_are_consistent

  private

  def certification_fields_are_consistent
    fields = [
      certification_epoch_height,
      certification_scope,
      certified_at
    ]

    populated =
      fields.count(&:present?)

    return if populated.zero?
    return if populated == fields.size

    errors.add(
      :base,
      "certification fields must be all present or all absent"
    )
  end
end
