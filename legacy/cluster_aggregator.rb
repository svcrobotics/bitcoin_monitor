# frozen_string_literal: true

# app/services/cluster_aggregator.rb
class ClusterAggregator
  def self.call(cluster)
    new(cluster).call
  end

  def initialize(cluster)
    @cluster = cluster
  end

  def call
    return nil if cluster.blank?

    stats = aggregate_address_stats
    return nil if stats[:cluster_size].zero?

    profile = ClusterProfile.find_or_initialize_by(cluster_id: cluster.id)

    profile.assign_attributes(
      cluster_size: stats[:cluster_size],
      tx_count: stats[:tx_count],
      total_sent_sats: stats[:total_sent_sats],
      first_seen_height: stats[:first_seen_height],
      last_seen_height: stats[:last_seen_height]
    )

    profile.save!

    ClusterClassifier.call(profile)
    ClusterScorer.call(profile)

    profile
  end

  private

  attr_reader :cluster

  def aggregate_address_stats
    row =
      Address
        .where(cluster_id: cluster.id)
        .pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(tx_count), 0)"),
          Arel.sql("COALESCE(SUM(total_sent_sats), 0)"),
          Arel.sql("MIN(first_seen_height)"),
          Arel.sql("MAX(last_seen_height)")
        )

    count, tx_count, total_sent_sats, first_seen, last_seen = row

    {
      cluster_size: count.to_i,
      tx_count: tx_count.to_i,
      total_sent_sats: total_sent_sats.to_i,
      first_seen_height: first_seen,
      last_seen_height: last_seen
    }
  end
end