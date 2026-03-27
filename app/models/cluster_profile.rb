class ClusterProfile < ApplicationRecord
  belongs_to :cluster

  validates :cluster_id, presence: true, uniqueness: true

  serialize :traits, coder: JSON

  def total_sent_btc
    return 0 if total_sent_sats.nil?
    (total_sent_sats.to_f / 100_000_000).round(4)
  end

  def traits_list
    Array(traits).compact
  rescue
    []
  end
end