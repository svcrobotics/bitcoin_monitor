# app/services/cluster_aggregator.rb
class ClusterAggregator
  def self.call(cluster)
    addresses = cluster.addresses
    return nil if addresses.blank?

    tx_count = addresses.sum(:tx_count)
    total_sent_sats = addresses.sum(:total_sent_sats)

    first_seen = addresses.minimum(:first_seen_height)
    last_seen  = addresses.maximum(:last_seen_height)

    profile = ClusterProfile.find_or_initialize_by(cluster_id: cluster.id)

    profile.update!(
      cluster_size: addresses.size,
      tx_count: tx_count,
      total_sent_sats: total_sent_sats,
      first_seen_height: first_seen,
      last_seen_height: last_seen
    )

    ClusterClassifier.call(profile)
    ClusterScorer.call(profile)

    profile
  end
end