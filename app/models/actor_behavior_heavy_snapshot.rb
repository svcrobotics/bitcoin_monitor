# frozen_string_literal: true

class ActorBehaviorHeavySnapshot <
  ApplicationRecord

  STATUSES = %w[
    certified
    failed
  ].freeze

  ANALYSIS_KINDS = %w[
    exchange_infrastructure
    service_infrastructure
  ].freeze

  belongs_to :cluster
  belongs_to :actor_profile
  belongs_to :actor_behavior_snapshot

  belongs_to(
    :downstream_cluster,
    class_name: "Cluster",
    optional: true
  )

  validates :cluster_id, presence: true
  validates :cluster_id, uniqueness: { scope: :analysis_kind }

  validates :actor_profile_id, presence: true
  validates :actor_behavior_snapshot_id, presence: true
  validates :downstream_cluster_id,
          presence: true,
          if: :exchange_infrastructure?

  validates(
    :analysis_kind,
    presence: true,
    inclusion: {
      in: ANALYSIS_KINDS
    }
  )

  validates :heavy_version, presence: true

  validates(
    :status,
    presence: true,
    inclusion: {
      in: STATUSES
    }
  )

  validates :source_profile_fingerprint, presence: true
  validates :source_profile_height, presence: true

  validates(
    :source_cluster_composition_version,
    presence: true
  )

  validates :source_behavior_version, presence: true

  validates :window_from_height, presence: true
  validates :window_to_height, presence: true

  validates :evidence_fingerprint, presence: true
  validates :computed_at, presence: true

  validate :valid_height_window

  def exchange_infrastructure?
    analysis_kind == "exchange_infrastructure"
  end

  private

  def valid_height_window
    return if window_from_height.blank?
    return if window_to_height.blank?

    return if window_from_height <=
              window_to_height

    errors.add(
      :window_from_height,
      "must be lower than or equal to window_to_height"
    )
  end
end
