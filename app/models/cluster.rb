class Cluster < ApplicationRecord
  has_many :addresses, dependent: :nullify
  has_one :cluster_profile, dependent: :destroy
  has_many :cluster_metrics, dependent: :delete_all
  has_many :cluster_signals, dependent: :delete_all
  
  def recalculate_stats!
    scoped = addresses

    update!(
      address_count: scoped.count,
      total_received_sats: scoped.sum(:total_received_sats),
      total_sent_sats: scoped.sum(:total_sent_sats),
      first_seen_height: scoped.minimum(:first_seen_height),
      last_seen_height: scoped.maximum(:last_seen_height)
    )
  end
end