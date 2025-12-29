class Brc20ScanRange < ApplicationRecord
  validates :from_height, :to_height, :scanned_at, presence: true
  validates :from_height, :to_height,
            numericality: { only_integer: true }

  validate :from_not_after_to

  scope :ordered, -> { order(:from_height, :to_height) }

  # Retourne les plages qui couvrent un bloc donné
  scope :covering, ->(height) {
    where("from_height <= ? AND to_height >= ?", height, height)
  }

  # Retourne toutes les plages qui intersectent [from..to]
  scope :overlapping_range, ->(from_h, to_h) {
    where("from_height <= ? AND to_height >= ?", to_h, from_h)
  }

  private

  def from_not_after_to
    return if from_height.nil? || to_height.nil?
    if from_height > to_height
      errors.add(:from_height, "ne peut pas être > to_height")
    end
  end
end
