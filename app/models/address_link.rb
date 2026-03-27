class AddressLink < ApplicationRecord
  LINK_TYPES = %w[multi_input].freeze

  belongs_to :address_a, class_name: "Address"
  belongs_to :address_b, class_name: "Address"

  validates :link_type, presence: true, inclusion: { in: LINK_TYPES }
  validate :different_addresses

  scope :multi_input, -> { where(link_type: "multi_input") }

  private

  def different_addresses
    return if address_a_id.blank? || address_b_id.blank?
    errors.add(:address_b_id, "must be different from address_a_id") if address_a_id == address_b_id
  end
end