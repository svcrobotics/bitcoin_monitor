# frozen_string_literal: true

class ActorBehaviorSnapshot < ApplicationRecord
  STATUSES = %w[certified deferred failed].freeze

  belongs_to :cluster
  belongs_to :actor_profile

  validates :profile_version, :profile_fingerprint, :behavior_version, presence: true
  validates :profile_height,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cluster_composition_version,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :status, inclusion: { in: STATUSES }
  validates :cluster_id, uniqueness: true
  validate :strict_certification_is_complete

  private

  def strict_certification_is_complete
    return unless status == "certified"

    errors.add(:source_hash, :blank) if source_hash.blank?
    errors.add(:certification_scope, :invalid) unless certification_scope == "strict"
    errors.add(:certified_at, :blank) if certified_at.blank?
  end
end
