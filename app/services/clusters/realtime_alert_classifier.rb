# frozen_string_literal: true

module Clusters
  class RealtimeAlertClassifier
    def self.call(**args)
      new(**args).call
    end

    def initialize(
      links_created:,
      address_count:,
      input_rows_count:,
      clusters_created:,
      clusters_merged:
    )
      @links_created = links_created.to_i
      @address_count = address_count.to_i
      @input_rows_count = input_rows_count.to_i
      @clusters_created = clusters_created.to_i
      @clusters_merged = clusters_merged.to_i
    end

    def call
      return large_link_creation_alert if links_created >= large_link_threshold
      return cluster_expansion_alert if clusters_created >= created_threshold && address_count >= address_threshold
      return cluster_merge_alert if clusters_merged >= merge_threshold
      nil
    end

    private

    attr_reader :links_created, :address_count, :input_rows_count, :clusters_created, :clusters_merged

    def cluster_merge_alert
      {
        signal_type: "cluster_merge",
        severity: clusters_merged >= 5 ? "high" : "medium",
        score: [[clusters_merged * 20, 50].max, 100].min
      }
    end

    def large_link_creation_alert
      {
        signal_type: "large_link_creation",
        severity: links_created >= 500 ? "high" : "medium",
        score: [[links_created / 10, 40].max, 100].min
      }
    end

    def cluster_expansion_alert
      {
        signal_type: "cluster_expansion",
        severity: address_count >= 100 ? "high" : "medium",
        score: [[address_count / 2, 40].max, 100].min
      }
    end

    def merge_threshold
      Integer(ENV.fetch("CLUSTER_ALERT_MERGE_THRESHOLD", "1"))
    end

    def large_link_threshold
      Integer(ENV.fetch("CLUSTER_ALERT_LINKS_THRESHOLD", "100"))
    end

    def created_threshold
      Integer(ENV.fetch("CLUSTER_ALERT_CREATED_THRESHOLD", "10"))
    end

    def address_threshold
      Integer(ENV.fetch("CLUSTER_ALERT_ADDRESS_THRESHOLD", "50"))
    end
  end
end
