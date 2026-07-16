# frozen_string_literal: true

class ClusterTransactionProjectionGeneration < ApplicationRecord
  STATUSES =
    %w[pending building certified failed stale replaced].freeze

  has_many(
    :facts,
    class_name: "ClusterTransactionFact",
    foreign_key: :projection_generation_id,
    inverse_of: :projection_generation,
    dependent: :delete_all
  )

  validates :cluster_id,
    :composition_version,
    :base_checkpoint_height,
    :base_checkpoint_hash,
    :checkpoint_height,
    :checkpoint_hash,
    :source,
    :status,
    presence: true

  validates :status,
    inclusion: {
      in: STATUSES
    }

  validates :composition_version,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 1
    }

  validates :base_checkpoint_height,
    :checkpoint_height,
    :inflow_count,
    :outflow_count,
    :tx_count,
    :facts_count,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }

  validate :certified_generation_has_certified_at
  validate :base_checkpoint_not_after_checkpoint

  scope :certified, -> {
    where(status: "certified")
  }

  scope :current_for, ->(cluster_id:, composition_version:) {
    certified
      .where(
        cluster_id: cluster_id
      )
      .where(
        composition_version: composition_version
      )
      .order(id: :desc)
  }

  def certified?
    status == "certified"
  end

  def stale?
    status == "stale"
  end

  def failed?
    status == "failed"
  end

  def replaced?
    status == "replaced"
  end

  private

  def certified_generation_has_certified_at
    return unless certified?
    return if certified_at.present?

    errors.add(:certified_at, :blank)
  end

  def base_checkpoint_not_after_checkpoint
    return if base_checkpoint_height.blank? || checkpoint_height.blank?
    return if base_checkpoint_height.to_i <= checkpoint_height.to_i

    errors.add(:base_checkpoint_height, :after_checkpoint)
  end
end
