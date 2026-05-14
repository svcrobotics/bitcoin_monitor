class ClusterActivityState < ApplicationRecord
  belongs_to :cluster

  validates :cluster_id, presence: true, uniqueness: true

  def inactive_days
    return nil if inactive_seconds.blank?

    (inactive_seconds.to_f / 1.day).round(2)
  end
end