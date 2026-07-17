# frozen_string_literal: true

class ActorBehaviorRun < ApplicationRecord
  STATUSES = %w[
    running
    completed
    completed_with_errors
    failed
  ].freeze

  TRIGGERS = %w[
    manual
    job
    test
  ].freeze

  MODES = %w[
    shadow
  ].freeze

  STALE_RUNNING_AFTER =
    40.minutes

  COUNTER_COLUMNS = %i[
    selected
    missing_selected
    stale_selected
    created_count
    updated_count
    unchanged_count
    deferred_count
    failed_count
  ].freeze

  validates :behavior_version, presence: true
  validates :mode, presence: true, inclusion: { in: MODES }
  validates :trigger, presence: true, inclusion: { in: TRIGGERS }
  validates :requested_limit,
            presence: true,
            numericality: {
              only_integer: true,
              greater_than: 0
            }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :started_at, presence: true
  validates :finished_at,
            presence: true,
            unless: :running?
  validates :duration_ms,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0
            },
            allow_nil: true
  validates :error_message, length: { maximum: 2_000 }, allow_nil: true

  COUNTER_COLUMNS.each do |column|
    validates column,
              presence: true,
              numericality: {
                only_integer: true,
                greater_than_or_equal_to: 0
              }
  end

  validate :finished_at_after_started_at
  validate :counter_invariant
  validate :completed_status_matches_failed_count
  validate :error_message_is_not_a_stack_trace

  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :successful, -> { completed }
  scope :stale_running,
        lambda {
          running.where(
            "started_at < ?",
            STALE_RUNNING_AFTER.ago
          )
        }

  def running?
    status == "running"
  end

  def completed?
    status == "completed"
  end

  def completed_with_errors?
    status == "completed_with_errors"
  end

  def failed?
    status == "failed"
  end

  private

  def finished_at_after_started_at
    return if started_at.blank? ||
              finished_at.blank?

    return if finished_at >= started_at

    errors.add(
      :finished_at,
      :before_started_at
    )
  end

  def counter_invariant
    return if selected.to_i ==
              created_count.to_i +
              updated_count.to_i +
              unchanged_count.to_i +
              deferred_count.to_i +
              failed_count.to_i

    errors.add(
      :selected,
      :counter_invariant
    )
  end

  def completed_status_matches_failed_count
    if completed? &&
       failed_count.to_i.positive?
      errors.add(
        :status,
        :failed_count_present
      )
    end

    return unless completed_with_errors? &&
                  failed_count.to_i.zero?

    errors.add(
      :status,
      :failed_count_missing
    )
  end

  def error_message_is_not_a_stack_trace
    return if error_message.blank?
    return unless error_message.include?("\n")

    errors.add(
      :error_message,
      :stack_trace
    )
  end
end
