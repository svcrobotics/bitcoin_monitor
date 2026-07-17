# frozen_string_literal: true

class ClusterTransactionProjectionBackfillItem < ApplicationRecord
  STATUSES = %w[pending building paused ready_to_certify certified stale failed].freeze
  STAGES =
    %w[
      cluster_inputs_received
      utxo_outputs_received
      cluster_inputs_spent
      counter_audit
      certification
    ].freeze

  belongs_to(
    :run,
    class_name: "ClusterTransactionProjectionBackfillRun",
    inverse_of: :items
  )

  belongs_to(
    :projection_generation,
    class_name: "ClusterTransactionProjectionGeneration",
    optional: true
  )

  validates :cluster_id,
    :composition_version,
    :status,
    :stage,
    presence: true

  validate :projection_generation_required_unless_pending

  validates :composition_version,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 1
    }

  validates :rows_scanned,
    :facts_written,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }

  validates :status,
    inclusion: {
      in: STATUSES
    }

  validates :stage,
    inclusion: {
      in: STAGES
    }

  def cursor_for(stage_name = stage)
    source_cursor.fetch(stage_name.to_s, 0).to_i
  end

  private

  def projection_generation_required_unless_pending
    return if projection_generation_id.present?
    return if status == "pending"

    errors.add(:projection_generation_id, :blank)
  end
end
