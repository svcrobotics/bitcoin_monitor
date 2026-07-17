# frozen_string_literal: true

class ClusterCompositionRevisionRepairCheckpoint < ApplicationRecord
  STATUSES =
    %w[pending processing completed failed].freeze

  validates :status,
    presence: true,
    inclusion: {
      in: STATUSES
    }

  validates :last_cluster_id,
    :scanned_count,
    :updated_count,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }
end
