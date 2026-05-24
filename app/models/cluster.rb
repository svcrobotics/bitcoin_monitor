class Cluster < ApplicationRecord
  has_many :addresses, dependent: :nullify
  has_one :cluster_profile, dependent: :destroy
  has_many :cluster_metrics, dependent: :delete_all
  has_many :cluster_signals, dependent: :delete_all
  has_many :actor_labels, dependent: :delete_all
  has_one :actor_metric, dependent: :delete
  
  def recalculate_stats!
    stats =
      addresses
        .pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(total_received_sats), 0)"),
          Arel.sql("COALESCE(SUM(total_sent_sats), 0)"),
          Arel.sql("MIN(first_seen_height)"),
          Arel.sql("MAX(last_seen_height)")
        )

    count, received, sent, first_seen, last_seen = stats

    update_columns(
      address_count: count.to_i,
      total_received_sats: received.to_i,
      total_sent_sats: sent.to_i,
      first_seen_height: first_seen,
      last_seen_height: last_seen,
      updated_at: Time.current
    )
  end
end