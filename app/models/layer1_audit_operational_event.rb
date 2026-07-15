# frozen_string_literal: true

class Layer1AuditOperationalEvent < ApplicationRecord
  EVENT_TYPES = %w[
    already_enqueued
    initial_marker_ownership_lost
    deferred_exhausted
    marker_renewal_failed
    marker_cleanup_failed
  ].freeze
  SEVERITIES = %w[info warning critical error].freeze

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :audited_height,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    allow_nil: true
  validates :defer_attempt,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    allow_nil: true
  validates :occurred_at, presence: true
  validate :metadata_is_an_object

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, "operational audit events are append-only" if persisted?

    super
  end

  private

  def metadata_is_an_object
    errors.add(:metadata, :invalid) unless metadata.is_a?(Hash)
  end
end
