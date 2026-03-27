class ClusterMetric < ApplicationRecord
  belongs_to :cluster

  validates :cluster_id, presence: true
  validates :snapshot_date, presence: true
  validates :snapshot_date, uniqueness: { scope: :cluster_id }

  def sent_btc_24h
    return 0 if sent_sats_24h.nil?
    (sent_sats_24h.to_f / 100_000_000).round(8)
  end

  def sent_btc_7d
    return 0 if sent_sats_7d.nil?
    (sent_sats_7d.to_f / 100_000_000).round(8)
  end
end