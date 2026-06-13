class ClusterClassifier
  def self.call(profile)
    cluster_size = profile.cluster_size.to_i
    tx_count     = profile.tx_count.to_i
    total_btc    = profile.total_sent_sats.to_f / 100_000_000.0

    primary_type =
      if cluster_size > 10_000 && tx_count > 10_000
        "exchange_like"
      elsif cluster_size > 1_000
        "service"
      elsif cluster_size > 1
        "retail"
      else
        "unknown"
      end

    traits = []
    traits << "large_cluster" if cluster_size > 1_000
    traits << "high_activity" if tx_count > 5_000
    traits << "high_volume" if total_btc > 1_000
    traits << "whale_like" if total_btc > 5_000 && cluster_size < 10_000

    profile.update!(
      classification: primary_type,
      traits: traits
    )

    profile
  end
end