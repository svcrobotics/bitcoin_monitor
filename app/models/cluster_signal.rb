class ClusterSignal < ApplicationRecord
  belongs_to :cluster

  validates :cluster_id, :snapshot_date, :signal_type, presence: true

  enum :severity, {
    low: "low",
    medium: "medium",
    high: "high"
  }
end