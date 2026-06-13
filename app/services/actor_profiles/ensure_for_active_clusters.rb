# frozen_string_literal: true

module ActorProfiles
  class EnsureForActiveClusters
    WINDOW_BLOCKS = 10

    def self.call(window_blocks: WINDOW_BLOCKS)
      new(window_blocks: window_blocks).call
    end

    def initialize(window_blocks:)
      @window_blocks = window_blocks.to_i
      @marked = 0
    end

    def call
      to = ClusterInput.maximum(:spent_block_height).to_i
      from = [to - @window_blocks, 0].max

      cluster_ids = ClusterInput
        .where(spent_block_height: from..to)
        .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
        .distinct
        .pluck("addresses.cluster_id")
        .compact

      with_profile = ActorProfile.where(cluster_id: cluster_ids).pluck(:cluster_id)
      missing = cluster_ids - with_profile

      missing.each do |cluster_id|
        ActorProfiles::DirtyMarker.mark(cluster_id)
        @marked += 1
      end

      {
        ok: true,
        from: from,
        to: to,
        active_clusters: cluster_ids.size,
        missing_profiles: missing.size,
        marked: @marked
      }
    end
  end
end
