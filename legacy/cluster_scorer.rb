class ClusterScorer
  def self.call(profile)
    cluster_size = profile.cluster_size.to_f
    tx_count     = profile.tx_count.to_f
    total_btc    = profile.total_sent_sats.to_f / 100_000_000.0

    size_score =
      if cluster_size <= 1
        5
      else
        [Math.log10(cluster_size + 1) * 16, 30].min
      end

    activity_score =
      if tx_count <= 1
        5
      else
        [Math.log10(tx_count + 1) * 14, 25].min
      end

    volume_score =
      if total_btc <= 0
        5
      else
        [Math.log10(total_btc + 1) * 11, 25].min
      end

    score = (size_score + activity_score + volume_score).round
    score = [[score, 0].max, 100].min

    profile.update!(score: score)
    profile
  end
end